import type { PostHog } from "posthog-node";

import { type Callback } from "@plotday/twister/tools/callbacks";
import type { Tasks as IRun } from "@plotday/twister/tools/tasks";

import { type TwistEnvironment, type Bindings } from "../../env";
import { type CallbacksState } from "../../state/callbacks";
import { Tool } from "./tool";

export type RunMessage = {
  priorityTwistId: string;
  path: string[];
  token: string;
};

export class Tasks extends Tool implements IRun {
  private callbacks: DurableObjectStub<CallbacksState>;
  private priorityTwistId: string;
  private twistId: string;
  private environment: TwistEnvironment;
  private path: string[]; // path to the tool within the twist
  private queue: Queue<RunMessage>;

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    priorityTwistId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityTwistId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    callbacks: DurableObjectNamespace<CallbacksState>;
    priorityTwistId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    queue: Queue<RunMessage>;
  }) {
    super();
    this.callbacks = Tasks.GetStub(options.callbacks, options.priorityTwistId);
    this.priorityTwistId = options.priorityTwistId;
    this.twistId = options.twistId;
    this.environment = options.environment;
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
        priorityTwistId: this.priorityTwistId,
        path: this.path,
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
      priorityTwistId: this.priorityTwistId,
      path: this.path,
    });
  }

  private async send(token: string) {
    await this.queue.send({
      priorityTwistId: this.priorityTwistId,
      path: this.path,
      token,
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
        const callbacks = Tasks.GetStub(
          env.CALLBACKS,
          message.body.priorityTwistId
        );
        // @ts-ignore - TypeScript type recursion workaround
        await callbacks.callCallback(message.body.token);
        message.ack();
      } catch (error) {
        console.error(`Failed to execute callback ${message.body}:`, error);
        postHog.captureException(error as Error, undefined, {
          priority_twist_id: message.body.priorityTwistId,
          path: message.body.path.join("/"),
          queue: batch.queue,
        });
        message.retry();
      }
    }
  }
}
