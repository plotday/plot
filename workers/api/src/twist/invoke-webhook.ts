import { createLogger } from "@plotday/worker-util";

import { createDb } from "../db";
import { type Bindings, type TwistEnvironment } from "../env";
import { CallbackError } from "../errors";
import type { LoadResult } from "../state/callbacks";
import { Usage } from "../state/usage";
import { disposeRpc } from "../utils/rpc";
import { handleTwistOperation } from "./error-handling";
import { twistFactory } from "./factory";

/**
 * An Error annotated with the owning user of the twist that raised it.
 * `invokeWebhookCallback` tags errors from the callback execution with the
 * twist_instance's `owner_id` so queue consumers can attribute the PostHog
 * capture to a real user (distinctId) rather than a random per-event UUID.
 */
export type ErrorWithTwistOwner = Error & { twistOwnerId?: string };

/**
 * Dispatch a webhook-style callback without holding the CallbacksState DO.
 *
 * The DO performs only a SQLite token lookup via
 * `CallbacksState.validateAndLoad`. The twist_instance / quota / archive
 * checks AND the long-running twist worker RPC run here in the calling
 * worker's execution context, so the DO's output gate is released
 * immediately. Holding the gate across Hyperdrive queries inside the DO
 * caused Cloudflare to reset the DO under load with "Internal error in
 * Durable Object storage caused object to be reset".
 *
 * Call sites: the WEBHOOK_QUEUE consumer (per-message dispatch), the
 * synchronous `/hook-sync/:token` route (needs the return value for the
 * HTTP response), and the `/callback/:token` action callback route.
 *
 * Error semantics mirror the previous DO-hosted path: callers can catch
 * `CallbackError` and branch on `getCallbackErrorType(...)` exactly as
 * before. `NOT_FOUND` / `EXPIRED` / `INVALID_TOKEN` indicate permanent
 * failures (ack the queue message, return 410 to HTTP senders);
 * `SUSPENDED` is retriable once the twist resumes.
 *
 * `fullToken` is the `doId:token` string returned by `callbacks.create()`
 * and stored by external providers — the same value `callCallback`
 * accepts.
 */
export async function invokeWebhookCallback(
  env: Bindings,
  ctx: { exports: ExecutionContext["exports"] },
  fullToken: string,
  ...args: any[]
): Promise<any> {
  const [doIdHex] = fullToken.split(":");
  if (!doIdHex || !/^[0-9a-f]{64}$/i.test(doIdHex)) {
    throw new CallbackError("INVALID_TOKEN_FORMAT", {
      operation: "invokeWebhookCallback",
      token: fullToken.substring(0, 8) + "...",
    });
  }

  const doId = env.CALLBACKS.idFromString(doIdHex);
  const callbacksStub = env.CALLBACKS.get(doId);

  // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
  const load = (await callbacksStub.validateAndLoad(fullToken)) as LoadResult;

  if ("__error" in load) {
    disposeRpc(callbacksStub);
    throw new CallbackError(load.type, load.context);
  }

  const { callback } = load;

  const db = createDb(env);
  try {
    // Worker-side twist_instance + quota validation. Previously inside
    // the DO; moved here so Hyperdrive RTT doesn't hold the DO's output
    // gate.
    const twistInstance = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select([
        "twist_instance.archived_at",
        "twist_instance.suspended_at",
        "twist_instance.suspended_version",
        "twist_instance.owner_id",
        "twist.execution_limit",
        "twist.environment",
        "twist.twist_package_id",
        "twist.version as current_version",
      ])
      .where("twist_instance.id", "=", callback.twistInstanceId)
      .executeTakeFirst();

    if (!twistInstance || twistInstance.archived_at) {
      // Orphaned callback — the twist was deleted or archived. Drop the
      // row so it stops getting redelivered.
      try {
        await callbacksStub.delete(fullToken);
      } catch {
        // ignore — best-effort cleanup
      }
      disposeRpc(callbacksStub);
      throw new CallbackError("NOT_FOUND", {
        operation: "invokeWebhookCallback",
        twistInstanceId: callback.twistInstanceId,
        reason: !twistInstance
          ? "Twist instance deleted"
          : "Twist instance archived",
      });
    }

    if (twistInstance.suspended_at) {
      // Auto-suspensions record the active twist version on
      // `suspended_version`. When the twist is redeployed, that version
      // no longer matches and we lazy-clear the suspension so each new
      // version gets a fresh start. Manual suspensions leave
      // `suspended_version` NULL and remain durable across deploys.
      if (
        twistInstance.suspended_version &&
        twistInstance.suspended_version !== twistInstance.current_version
      ) {
        await db
          .updateTable("twist_instance")
          .set({ suspended_at: null, suspended_version: null })
          .where("id", "=", callback.twistInstanceId)
          .execute();
      } else {
        disposeRpc(callbacksStub);
        throw new CallbackError("SUSPENDED", {
          operation: "invokeWebhookCallback",
          twistInstanceId: callback.twistInstanceId,
          reason: "Twist processing suspended",
        });
      }
    }

    const usage = Usage.Get(env, callback.twistInstanceId);
    const withinBurst = await usage.checkBurstQuota();
    if (!withinBurst) {
      disposeRpc(callbacksStub);
      throw new CallbackError("SUSPENDED", {
        operation: "invokeWebhookCallback",
        twistInstanceId: callback.twistInstanceId,
        reason: "Twist processing suspended due to burst rate limit exceeded",
      });
    }
    const withinQuota = await usage.checkExecutionQuota(
      twistInstance.execution_limit
    );
    if (!withinQuota) {
      disposeRpc(callbacksStub);
      throw new CallbackError("SUSPENDED", {
        operation: "invokeWebhookCallback",
        twistInstanceId: callback.twistInstanceId,
        reason: "Twist processing suspended due to execution quota exceeded",
      });
    }

    const twistPackageId = twistInstance.twist_package_id;
    const environment = twistInstance.environment as TwistEnvironment;

    const factory = twistFactory({ env, ctx, db });
    const twistWrapper = await factory({
      version: callback.version,
      twistInstanceId: callback.twistInstanceId,
    });

    // Per-callback structured timing. The connector worker is loaded via
    // LOADER and has no PostHog observability binding (see
    // workers/api/src/twist/loader.ts), so logs from inside connector
    // code only flow to TWIST_LOGS_QUEUE. These boundary logs surface
    // throughput + p50/p99 + outcome to PostHog so we can see when a
    // specific connector operation is slow or flaking without
    // instrumenting every connector individually.
    const invocationLogger = createLogger({
      operation: "invokeWebhookCallback",
      twist_instance_id: callback.twistInstanceId,
      function_name: callback.functionName,
      tool_path: callback.path.join("/"),
      twist_id: twistPackageId,
      twist_version: callback.version,
      environment,
    });
    const rpcStartedAt = Date.now();
    invocationLogger.info("Twist callback RPC started");

    try {
      const callResult = await handleTwistOperation(
        `callback: ${callback.functionName}`,
        async () => {
          return await twistWrapper.callCallback(
            callback.path,
            callback.functionName,
            ...(args ?? []),
            ...(callback.extraArgs ?? [])
          );
        },
        {
          env,
          id: twistPackageId,
          version: callback.version,
          environment,
        }
      );

      invocationLogger.info("Twist callback RPC finished", {
        duration_ms: Date.now() - rpcStartedAt,
        outcome: "success",
      });

      if (callback.callOnce) {
        await callbacksStub.delete(fullToken);
      }
      disposeRpc(callbacksStub);
      return callResult;
    } catch (error) {
      const durationMs = Date.now() - rpcStartedAt;

      // Tag the error with the owning user so the queue consumer can
      // attribute the PostHog capture to a real person instead of a random
      // per-event distinct_id. owner_id is the user UUID — the distinctId
      // convention used across the worker (see state/*.ts captureException).
      if (error instanceof Error) {
        (error as ErrorWithTwistOwner).twistOwnerId = twistInstance.owner_id;
      }

      // If the tool path no longer exists, the callback is orphaned —
      // delete so it doesn't keep failing on retry.
      if (
        error instanceof Error &&
        error.message.includes("Tool not found at path")
      ) {
        invocationLogger.warn("Deleting callback for removed tool", {
          duration_ms: durationMs,
          outcome: "orphaned_tool",
          token: fullToken.substring(0, 8) + "...",
        });
        try {
          await callbacksStub.delete(fullToken);
        } catch {
          // ignore — we're already in an error path
        }
      } else {
        // handleTwistOperation has already captureException'd this; we're
        // just adding the boundary-level timing/outcome marker so it's
        // joinable with the started log via twist_instance_id +
        // function_name + a close-by timestamp.
        invocationLogger.warn("Twist callback RPC finished", {
          duration_ms: durationMs,
          outcome: "failure",
          error_message: error instanceof Error ? error.message : String(error),
        });
      }
      disposeRpc(callbacksStub);
      throw error;
    }
  } finally {
    await db.destroy();
  }
}
