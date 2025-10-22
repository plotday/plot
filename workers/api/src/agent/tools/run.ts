import type { Callback } from "@plotday/sdk/tools/callback";
import type { Run as IRun } from "@plotday/sdk/tools/run";

import { type Bindings } from "../../env";
import { type Callbacks } from "../../state/callbacks";
import { Tool } from "./tool";

export type RunMessage = {
  priorityAgentId: string;
  path: string[];
  token: string;
};

export class Run extends Tool implements IRun {
  private callbacks: DurableObjectStub<Callbacks>;
  private priorityAgentId: string;
  private agentId: string;
  private environment: string;
  private path: string[]; // path to the tool within the agent
  private queue: Queue<RunMessage>;

  private static GetStub(
    callbacks: DurableObjectNamespace<Callbacks>,
    priorityAgentId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityAgentId);
    return callbacks.get(callbacksId);
  }

  constructor({
    callbacks,
    priorityAgentId,
    agentId,
    environment,
    path,
    queue,
  }: {
    callbacks: DurableObjectNamespace<Callbacks>;
    priorityAgentId: string;
    agentId: string;
    environment: string;
    path: string[];
    queue: Queue<RunMessage>;
  }) {
    super();
    this.callbacks = Run.GetStub(callbacks, priorityAgentId);
    this.priorityAgentId = priorityAgentId;
    this.agentId = agentId;
    this.environment = environment;
    // remove final element, which is the ID of this tool
    this.path = path.slice(0, -1);
    this.queue = queue;
  }

  async run(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void> {
    if (options?.runAt) {
      // Schedule for later execution
      return await this.callbacks.create({
        priorityAgentId: this.priorityAgentId,
        agentId: this.agentId,
        environment: this.environment,
        path: this.path,
        functionName: "scheduledSend",
        context: callback,
        callAt: options.runAt,
      });
    } else {
      // Send immediately to queue
      await this.send(callback);
    }
  }

  async cancel(token: string): Promise<void> {
    await this.callbacks.delete(token);
  }

  async cancelAll(): Promise<void> {
    await this.callbacks.deleteAll({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path,
    });
  }

  private async send(token: string) {
    await this.queue.send({
      priorityAgentId: this.priorityAgentId,
      path: this.path,
      token,
    });
  }

  private async scheduledSend(__args: any, token: string) {
    await this.send(token);
  }

  static async processQueue(env: Bindings, batch: MessageBatch<RunMessage>) {
    for (const message of batch.messages) {
      try {
        const callbacks = Run.GetStub(
          env.CALLBACKS,
          message.body.priorityAgentId
        );
        // @ts-ignore - TypeScript type recursion workaround
        await callbacks.callCallback(message.body.token);
        message.ack();
      } catch (error) {
        console.error(`Failed to execute callback ${message.body}:`, error);
        message.retry();
      }
    }
  }
}
