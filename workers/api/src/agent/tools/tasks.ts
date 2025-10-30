import { type Callback } from "@plotday/agent/tools/callbacks";
import type { Tasks as IRun } from "@plotday/agent/tools/tasks";

import { type AgentEnvironment, type Bindings } from "../../env";
import { type CallbacksState } from "../../state/callbacks";
import { Tool } from "./tool";

export type RunMessage = {
  priorityAgentId: string;
  path: string[];
  token: string;
};

export class Tasks extends Tool implements IRun {
  private callbacks: DurableObjectStub<CallbacksState>;
  private priorityAgentId: string;
  private agentId: string;
  private environment: AgentEnvironment;
  private path: string[]; // path to the tool within the agent
  private queue: Queue<RunMessage>;

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    priorityAgentId: string
  ) {
    const callbacksId = callbacks.idFromName(priorityAgentId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    callbacks: DurableObjectNamespace<CallbacksState>;
    priorityAgentId: string;
    agentId: string;
    environment: AgentEnvironment;
    path: string[];
    queue: Queue<RunMessage>;
  }) {
    super();
    this.callbacks = Tasks.GetStub(options.callbacks, options.priorityAgentId);
    this.priorityAgentId = options.priorityAgentId;
    this.agentId = options.agentId;
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
        priorityAgentId: this.priorityAgentId,
        agentId: this.agentId,
        environment: this.environment,
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

  private async scheduledSend(token: string) {
    await this.send(token);
  }

  static async processQueue(env: Bindings, batch: MessageBatch<RunMessage>) {
    for (const message of batch.messages) {
      try {
        const callbacks = Tasks.GetStub(
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
