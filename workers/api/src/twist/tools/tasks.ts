import type { PostHog } from "posthog-node";

import { type Callback } from "@plotday/twister/tools/callbacks";
import type { Tasks as IRun } from "@plotday/twister/tools/tasks";

import { type Bindings, type TwistEnvironment } from "../../env";
import { isCallbackError } from "../../errors";
import { type CallbacksState } from "../../state/callbacks";
import { extractRunQueueContext } from "../../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import {
  type ErrorWithTwistOwner,
  invokeWebhookCallback,
} from "../invoke-webhook";
import { disposeRpc } from "../../utils/rpc";
import {
  isAuthError,
  isRateLimitError,
  isTransientError,
} from "../../utils/transient-error";
import { Tool } from "./tool";

export type RunMessage = {
  twistInstanceId: string;
  path: string[];
  token: string;
  queuedAt?: number;
};

export class Tasks extends Tool implements IRun {
  private callbacks: DurableObjectStub<CallbacksState>;
  private twistInstanceId: string;
  private twistId: string;
  private environment: TwistEnvironment;
  private path: string[]; // path to the parent tool
  private selfPath: string[]; // full path including this tool
  private queue: Queue<RunMessage>;

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    twistInstanceId: string
  ) {
    const callbacksId = callbacks.idFromName(twistInstanceId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    callbacks: DurableObjectNamespace<CallbacksState>;
    twistInstanceId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    queue: Queue<RunMessage>;
  }) {
    super();
    this.callbacks = Tasks.GetStub(options.callbacks, options.twistInstanceId);
    this.twistInstanceId = options.twistInstanceId;
    this.twistId = options.twistId;
    this.environment = options.environment;
    this.selfPath = options.path;
    // remove final element, which is the ID of this tool
    this.path = options.path.slice(0, -1);
    this.queue = options.queue;
  }

  async runTask(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void> {
    if (options?.runAt) {
      // Schedule for later execution
      return await this.callbacks.create({
        twistInstanceId: this.twistInstanceId,
        path: this.selfPath,
        functionName: "scheduledSend",
        extraArgs: [callback],
        callAt: options.runAt,
      });
    } else {
      // Send immediately to queue
      await this.send(callback);
    }
  }

  async cancelTask(token: string): Promise<void> {
    await this.callbacks.delete(token);
  }

  async cancelAllTasks(): Promise<void> {
    await this.callbacks.deleteAll({
      twistInstanceId: this.twistInstanceId,
      path: this.selfPath,
    });
  }

  async scheduleTask(
    key: string,
    callback: Callback,
    options: { runAt: Date }
  ): Promise<string | void> {
    // Same scheduled wrapper as runTask({ runAt }), but tagged with task_key
    // so the DO atomically replaces any pending task under the same key —
    // guaranteeing at most one live scheduled task per key (no leaked chains).
    return await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.selfPath,
      functionName: "scheduledSend",
      extraArgs: [callback],
      callAt: options.runAt,
      taskKey: key,
    });
  }

  async cancelScheduledTask(key: string): Promise<void> {
    await this.callbacks.deleteByTaskKey(this.twistInstanceId, key);
  }

  private async send(token: string) {
    const message: RunMessage = {
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      token,
      queuedAt: Date.now(),
    };
    // Producer-side instrumentation: pairs with the consumer-side
    // "RunMessage invocation started/finished" logs in processQueue. If
    // a connector call (e.g. onChannelEnabled → runTask) silently
    // returns without enqueueing, we'll see the absence of these events
    // and know the producer never called us. If queue.send fails (or
    // exhausts retries) we record outcome=failure here. Joinable on
    // twist_instance_id + token + close-by timestamps.
    const logger = createLogger({
      operation: "Tasks.send",
      twist_instance_id: this.twistInstanceId,
      tool_path: this.path.join("/"),
    });
    const startedAt = Date.now();
    logger.info("Tasks.send started", {
      token: token.split(":")[1]?.substring(0, 8) ?? token.substring(0, 8),
    });

    // Retry transient Cloudflare Queues producer errors (e.g. "Queue send
    // failed: Bad Gateway"). Without retry, the alarm handler in
    // CallbacksState clears call_at on throw and the scheduled task is
    // lost — and the failure escalates to PostHog as an unhandled twist
    // exception via handleTwistOperation.
    const delaysMs = [100, 400];
    for (let attempt = 0; ; attempt++) {
      try {
        await this.queue.send(message);
        logger.info("Tasks.send finished", {
          duration_ms: Date.now() - startedAt,
          attempt,
          outcome: "success",
        });
        return;
      } catch (error) {
        if (attempt < delaysMs.length && isTransientError(error)) {
          logger.warn("Tasks.send transient error, retrying", {
            attempt,
            delay_ms: delaysMs[attempt],
            error: String(error),
          });
          await new Promise((r) => setTimeout(r, delaysMs[attempt]));
          continue;
        }
        logger.error("Tasks.send finished", error as Error, {
          duration_ms: Date.now() - startedAt,
          attempt,
          outcome: "failure",
        });
        throw error;
      }
    }
  }

  private async scheduledSend(token: string) {
    await this.send(token);
  }

  static async processQueue(
    env: Bindings,
    ctx: { exports: ExecutionContext["exports"] },
    batch: MessageBatch<RunMessage>,
    postHog: PostHog
  ) {
    // Dispatch each message independently: one slow task should not hold
    // up its batch-mates, and invokeWebhookCallback keeps the twist RPC
    // out of the CallbacksState DO so the DO's output gate stays free.
    //
    // Every invocation emits a structured `RunMessage invocation finished`
    // log with duration_ms + outcome ("success" | "transient_retry" |
    // "callback_error_ack" | "failure_retry"). PostHog ingests these so
    // we can see queue throughput, slow tasks, and per-twist error rates
    // without spelunking through individual error-tracking issues.
    const handleMessage = async (
      message: Message<RunMessage>
    ): Promise<void> => {
      const baseContext = extractRunQueueContext(message.body, batch.queue);
      const logger = createLogger({
        ...baseContext,
        attempts: message.attempts,
      });
      const startedAt = Date.now();
      const queueWaitMs = message.body.queuedAt
        ? startedAt - message.body.queuedAt
        : undefined;

      logger.info("RunMessage invocation started", {
        ...(queueWaitMs !== undefined ? { queue_wait_ms: queueWaitMs } : {}),
      });

      try {
        const result = await invokeWebhookCallback(
          env,
          ctx,
          message.body.token
        );
        disposeRpc(result);
        message.ack();

        logger.info("RunMessage invocation finished", {
          duration_ms: Date.now() - startedAt,
          ...(queueWaitMs !== undefined ? { queue_wait_ms: queueWaitMs } : {}),
          outcome: "success",
        });
      } catch (error) {
        const durationMs = Date.now() - startedAt;

        if (isTransientError(error)) {
          logger.warn("RunMessage invocation finished", {
            duration_ms: durationMs,
            outcome: "transient_retry",
            error: String(error),
          });
          message.retry();
          return;
        }

        // Downstream provider rate-limit / quota errors (Gmail/Google 403
        // rateLimitExceeded, HTTP 429). Expected under load and self-
        // resolving, so retry without paging PostHog Error Tracking — see
        // isRateLimitError. Retrying (not acking) lets the message process
        // once the provider's rate window clears.
        if (isRateLimitError(error)) {
          logger.warn("RunMessage invocation finished", {
            duration_ms: durationMs,
            outcome: "rate_limited_retry",
            error: String(error),
          });
          message.retry();
          return;
        }

        // Terminal auth errors (revoked/expired-unrefreshable OAuth token,
        // invalid credentials). Retrying loops the same 401 until the queue's
        // cap — the storm behind PostHog 019dbbae. ACK to drop it; the token
        // is dead until re-auth, and getActorToken already flags
        // needs_reauth_at on the next expiry, which drives the app's re-auth
        // prompt. Do not page PostHog (expected condition, user re-auths).
        if (isAuthError(error)) {
          logger.warn("RunMessage invocation finished", {
            duration_ms: durationMs,
            outcome: "auth_error_ack",
            error: String(error),
          });
          message.ack();
          return;
        }

        if (isCallbackError(error)) {
          logger.warn("RunMessage invocation finished", {
            duration_ms: durationMs,
            outcome: "callback_error_ack",
            error: String(error),
          });
          message.ack();
          return;
        }

        logger.error(
          "RunMessage invocation finished",
          error as Error,
          {
            duration_ms: durationMs,
            outcome: "failure_retry",
          }
        );
        // Attribute the capture to the owning user (distinctId) when
        // invokeWebhookCallback tagged the error — otherwise PostHog mints a
        // random per-event distinct_id and the issue shows a UUID instead of
        // the user. owner_id is the user UUID, matching the worker-wide
        // captureException distinctId convention.
        const ownerId = (error as ErrorWithTwistOwner)?.twistOwnerId;
        postHog.captureException(error as Error, ownerId, {
          twist_instance_id: message.body.twistInstanceId,
          path: message.body.path.join("/"),
          queue: batch.queue,
          attempts: message.attempts,
          duration_ms: durationMs,
        });
        message.retry();
      }
    };

    await Promise.allSettled(batch.messages.map(handleMessage));
  }
}
