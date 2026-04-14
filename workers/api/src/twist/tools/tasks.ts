import type { PostHog } from "posthog-node";

import { type Callback } from "@plotday/twister/tools/callbacks";
import type { Tasks as IRun } from "@plotday/twister/tools/tasks";

import { type Bindings, type TwistEnvironment } from "../../env";
import { isCallbackError } from "../../errors";
import { type CallbacksState } from "../../state/callbacks";
import { extractRunQueueContext } from "../../utils/log-context";
import { createLogger } from "@plotday/worker-util";
import { Tool } from "./tool";

/**
 * Detect transient infrastructure errors (DO communication failures,
 * Hyperdrive connection issues) that should be retried silently without
 * reporting to PostHog.
 */
function isTransientError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const msg = error.message;
  return (
    msg.includes("Network connection lost") ||
    msg.includes("error code: 1019") ||
    msg.includes("The Durable Object") ||
    msg.includes("internal error")
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
    await this.queue.send({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      token,
      queuedAt: Date.now(),
    });
  }

  private async scheduledSend(token: string) {
    await this.send(token);
  }

  static async processQueue(
    env: Bindings,
    batch: MessageBatch<RunMessage>,
    postHog: PostHog
  ) {
    for (const message of batch.messages) {
      try {
        if (env.SYNC_TIMING_ENABLED === "true" && message.body.queuedAt) {
          const queueWaitMs = Date.now() - message.body.queuedAt;
          const context = extractRunQueueContext(message.body, batch.queue);
          const logger = createLogger(context);
          logger.info("Queue wait time", { queue_wait_ms: queueWaitMs });
        }

        const callbacks = Tasks.GetStub(
          env.CALLBACKS,
          message.body.twistInstanceId
        );
        using _result = await callbacks.callCallback(message.body.token);
        message.ack();
      } catch (error) {
        const context = extractRunQueueContext(message.body, batch.queue);
        const logger = createLogger(context);

        // Transient infrastructure errors (DO communication, Hyperdrive) —
        // retry silently without PostHog noise
        if (isTransientError(error)) {
          logger.warn("Transient error executing callback, retrying", {
            error: String(error),
          });
          message.retry();
          continue;
        }

        // CallbackErrors crossing DO boundary (NOT_FOUND, EXPIRED, etc.) —
        // permanent failures, ack to prevent infinite retries
        if (isCallbackError(error)) {
          logger.warn("Callback error, acking message", {
            error: String(error),
          });
          message.ack();
          continue;
        }

        logger.error("Failed to execute callback", error as Error);
        postHog.captureException(error as Error, undefined, {
          twist_instance_id: message.body.twistInstanceId,
          path: message.body.path.join("/"),
          queue: batch.queue,
        });
        message.retry();
      }
    }
  }
}
