import type { PostHog } from "posthog-node";

import { type Callback } from "@plotday/twister/tools/callbacks";
import type { Tasks as IRun } from "@plotday/twister/tools/tasks";

import { type Bindings, type TwistEnvironment } from "../../env";
import { isCallbackError } from "../../errors";
import { type CallbacksState } from "../../state/callbacks";
import { extractRunQueueContext } from "../../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { invokeWebhookCallback } from "../invoke-webhook";
import { disposeRpc } from "../../utils/rpc";
import { Tool } from "./tool";

/**
 * Detect transient infrastructure errors that should be retried without
 * paging PostHog Error Tracking. The bar for inclusion is high: we only
 * silence patterns that are unambiguously platform-side and self-resolve
 * within seconds. Generic patterns like "internal error" or "The Durable
 * Object" mask real bugs (the connector worker crashing, a DO output-
 * gate violation, an unhandled throw inside user code that happens to
 * include those words) and stall investigation.
 *
 * If you find yourself wanting to add a broad pattern here to quiet a
 * flood, fix the underlying flake instead. handleTwistOperation already
 * calls tracker.captureException for everything that bubbles up, so
 * silencing here only changes retry semantics — not visibility.
 */
function isTransientError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    // Cloudflare network blip — typically resolves in seconds.
    msg.includes("Network connection lost") ||
    // Cloudflare bot-block / rate-limit — resolves on the next attempt.
    msg.includes("error code: 1019") ||
    // DO version churn during a deploy: the platform resets the DO so
    // the new code can take over. Retry picks up the new version cleanly.
    msg.includes("Durable Object reset because its code was updated") ||
    // Queues producer 5xx is well-defined and the only producer-side
    // path that's worth a silent retry. Anything more generic ("Bad
    // Gateway", "internal error") could be a real downstream failure.
    msg.includes("Queue send failed: Internal Server Error")
  );
}

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

  private async send(token: string) {
    const message: RunMessage = {
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      token,
      queuedAt: Date.now(),
    };
    // Retry transient Cloudflare Queues producer errors (e.g. "Queue send
    // failed: Bad Gateway"). Without retry, the alarm handler in
    // CallbacksState clears call_at on throw and the scheduled task is
    // lost — and the failure escalates to PostHog as an unhandled twist
    // exception via handleTwistOperation.
    const delaysMs = [100, 400];
    for (let attempt = 0; ; attempt++) {
      try {
        await this.queue.send(message);
        return;
      } catch (error) {
        if (attempt < delaysMs.length && isTransientError(error)) {
          await new Promise((r) => setTimeout(r, delaysMs[attempt]));
          continue;
        }
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
        postHog.captureException(error as Error, undefined, {
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
