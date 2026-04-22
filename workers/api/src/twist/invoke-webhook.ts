import { createLogger } from "@plotday/worker-util";

import { createDb } from "../db";
import type { Bindings } from "../env";
import { CallbackError } from "../errors";
import type { LoadResult } from "../state/callbacks";
import { disposeRpc } from "../utils/rpc";
import { handleTwistOperation } from "./error-handling";
import { twistFactory } from "./factory";

/**
 * Dispatch a webhook-style callback without holding the CallbacksState DO.
 *
 * The DO only performs the cheap part — token lookup, twist_instance
 * lifecycle checks, and the execution-quota check — via
 * `CallbacksState.validateAndLoad`. The long-running twist worker RPC
 * runs here, in the calling worker's execution context, so the DO's
 * output gate is released long before the twist callback finishes.
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

  let load: LoadResult;
  try {
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    load = (await callbacksStub.validateAndLoad(fullToken)) as LoadResult;
  } finally {
    // If validateAndLoad threw we still want to drop the stub; the DO RPC
    // runtime otherwise logs "An RPC stub was not disposed properly".
  }

  if ("__error" in load) {
    disposeRpc(callbacksStub);
    throw new CallbackError(load.type, load.context);
  }

  const { callback, twistPackageId, environment } = load;

  const db = createDb(env);
  try {
    const factory = twistFactory({ env, ctx, db });
    const twistWrapper = await factory({
      version: callback.version,
      twistInstanceId: callback.twistInstanceId,
    });

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

      if (callback.callOnce) {
        await callbacksStub.delete(fullToken);
      }
      disposeRpc(callbacksStub);
      return callResult;
    } catch (error) {
      // If the tool path no longer exists, the callback is orphaned —
      // delete so it doesn't keep failing on retry.
      if (
        error instanceof Error &&
        error.message.includes("Tool not found at path")
      ) {
        const logger = createLogger({
          operation: "invokeWebhookCallback",
          twist_instance_id: callback.twistInstanceId,
        });
        logger.warn("Deleting callback for removed tool", {
          token: fullToken.substring(0, 8) + "...",
          path: callback.path.join(" > "),
          function_name: callback.functionName,
        });
        try {
          await callbacksStub.delete(fullToken);
        } catch {
          // ignore — we're already in an error path
        }
      }
      disposeRpc(callbacksStub);
      throw error;
    }
  } finally {
    await db.destroy();
  }
}
