import { type Bindings } from "../../env";
import { type Callbacks } from "../../state/callbacks";
import type { Run as IRun } from "../types/tools/run";
import { Tool } from "./tool";

export type RunMessage = {
  priorityAgentId: string;
  path: string[];
  token: string;
};

export class Run extends Tool implements IRun {
  private callbacks: DurableObjectStub<Callbacks>;
  private priorityAgentId: string;
  private path: string[]; // path to the tool within the agent
  private queue: Queue<RunMessage>;

  private static GetStub(
    callbacks: DurableObjectNamespace<Callbacks>,
    priorityAgentId: string,
    path: string[]
  ) {
    const callbacksId = callbacks.idFromName(
      `${priorityAgentId}:${path.join(":")}`
    );
    return callbacks.get(callbacksId);
  }

  constructor({
    callbacks,
    priorityAgentId,
    path,
    queue,
  }: {
    callbacks: DurableObjectNamespace<Callbacks>;
    priorityAgentId: string;
    path: string[];
    queue: Queue<RunMessage>;
  }) {
    super();
    this.callbacks = Run.GetStub(callbacks, priorityAgentId, path);
    this.priorityAgentId = priorityAgentId;
    // remove final element, which is the ID of this tool
    this.path = path;
    this.queue = queue;
  }

  async now(callbackName: string, context?: any): Promise<void> {
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      path: this.path.slice(0, -1),
      functionName: callbackName,
      context,
      callOnce: true,
    });

    // Send immediately to queue
    await this.send(token);
  }

  async later(
    callbackName: string,
    executeAt: Date,
    context?: any
  ): Promise<string> {
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      path: this.path.slice(0, -1),
      functionName: callbackName,
      context,
      callOnce: true,
    });

    return await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      path: this.path,
      functionName: "scheduledSend",
      context: token,
      callAt: executeAt,
    });
  }

  async cancel(token: string): Promise<void> {
    await this.callbacks.delete(token);
  }

  async cancelAll(): Promise<void> {
    await this.callbacks.deleteAll({ reallyDeleteEverything: true });
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
          message.body.priorityAgentId,
          message.body.path
        );
        // @ts-ignore - TypeScript type recursion workaround
        await callbacks.call(message.body.token);
        message.ack();
      } catch (error) {
        console.error(`Failed to execute callback ${message.body}:`, error);
        message.retry();
      }
    }
  }
}
