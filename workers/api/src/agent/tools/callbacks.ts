import { type ActivityLink, ActivityLinkType } from "@plotday/agent/plot";
import type {
  Callback,
  Callbacks as ICallbackTool,
} from "@plotday/agent/tools/callbacks";

import { type AgentEnvironment } from "../../env";
import { CallbacksState } from "../../state/callbacks";
import { getRpcFunctionName } from "../../utils/rpc";
import { Tool } from "./tool";

export * from "@plotday/agent/tools/callbacks";

export class Callbacks extends Tool implements ICallbackTool {
  private callbacks: DurableObjectStub<CallbacksState>;
  private priorityAgentId: string;
  private agentId: string;
  private environment: AgentEnvironment;
  private path: string[];

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
  }) {
    super();
    this.callbacks = Callbacks.GetStub(
      options.callbacks,
      options.priorityAgentId
    );
    this.priorityAgentId = options.priorityAgentId;
    this.agentId = options.agentId;
    this.environment = options.environment;
    // Remove this tool
    this.path = options.path.slice(0, -1);
  }

  async create(fn: Function, ...extraArgs: any[]): Promise<Callback> {
    const functionName = await getRpcFunctionName(fn);
    if (!functionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path,
      functionName,
      extraArgs,
    });

    return token as Callback;
  }

  async createFromParent(fn: Function, ...extraArgs: any[]): Promise<Callback> {
    const functionName = await getRpcFunctionName(fn);
    if (!functionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path.slice(0, -1),
      functionName,
      extraArgs,
    });

    return token as Callback;
  }

  // Call a callback from another tool
  static async CallCallback(
    callbacks: DurableObjectNamespace<CallbacksState>,
    callback: Callback,
    args?: any
  ): Promise<any> {
    return await CallbacksState.CallCallback(callbacks, callback, args);
  }

  async run(callback: Callback, ...args: any[]): Promise<any> {
    return await this.callbacks.callCallback(callback, ...(args ?? []));
  }

  async delete(callback: Callback): Promise<void> {
    await this.callbacks.delete(callback);
  }

  async deleteAll(): Promise<void> {
    await this.callbacks.deleteAll({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path,
    });
  }

  /**
   * Static method to handle activity link callbacks from API endpoints
   */
  static async HandleLinkCallback(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    link: ActivityLink
  ): Promise<any> {
    try {
      // Extract callback token from the link
      if (link.type !== ActivityLinkType.callback) {
        throw new Error("Link is not a callback type");
      }

      const callbackToken = link.token;
      if (!callbackToken) {
        throw new Error("No callback token found in activity link");
      }

      if (callbackToken !== token) {
        throw new Error("Callback token mismatch");
      }

      // Execute the callback with the full activity link as argument
      const result = await CallbacksState.CallCallback(
        callbacks,
        callbackToken,
        link
      );

      return result;
    } catch (error) {
      console.error("Error handling link callback:", error);
      throw error;
    }
  }
}
