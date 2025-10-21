import { Callbacks } from "../../state/callbacks";
import { type ActivityLink, ActivityLinkType } from "@plotday/sdk/plot";
import type {
  Callback,
  CallbackContext,
  CallbackMethods,
  CallbackTool as ICallbackTool,
} from "@plotday/sdk/tools/callback";
import { Tool } from "./tool";

export * from "@plotday/sdk/tools/callback";

export class CallbackTool<TParent = any> extends Tool implements ICallbackTool<TParent> {
  private callbacks: DurableObjectStub<Callbacks>;
  private priorityAgentId: string;
  private agentId: string;
  private environment: string;
  private path: string[];

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
  }: {
    callbacks: DurableObjectNamespace<Callbacks>;
    priorityAgentId: string;
    agentId: string;
    environment: string;
    path: string[];
  }) {
    super();
    this.callbacks = CallbackTool.GetStub(callbacks, priorityAgentId);
    this.priorityAgentId = priorityAgentId;
    this.agentId = agentId;
    this.environment = environment;
    // Remove this tool
    this.path = path.slice(0, -1);
  }

  async create<K extends CallbackMethods<TParent>>(
    functionName: K,
    context?: CallbackContext<TParent, K>
  ): Promise<Callback> {
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      agentId: this.agentId,
      environment: this.environment,
      path: this.path,
      functionName: functionName as string,
      context,
    });

    return token as Callback;
  }

  // Call a callback from another tool
  static async Call(
    callbacks: DurableObjectNamespace<Callbacks>,
    callback: Callback,
    args?: any
  ): Promise<any> {
    const { shardKey } = Callbacks.parseToken(callback);
    const callbacksId = callbacks.idFromName(shardKey);
    const callbacksStub = callbacks.get(callbacksId);
    // @ts-ignore nested type issue
    return await callbacksStub.call(callback, args);
  }

  async call(callback: Callback, args?: any): Promise<any> {
    return await this.callbacks.call(callback, args);
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
   * Similar to Auth.HandleOauthCallback() pattern
   */
  static async HandleLinkCallback(
    callbacks: DurableObjectNamespace<Callbacks>,
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

      // Parse token to get shard key for routing
      const { shardKey } = Callbacks.parseToken(callbackToken);
      const callbacksId = callbacks.idFromName(shardKey);
      const callbacksStub = callbacks.get(callbacksId);

      // Execute the callback with the full activity link as argument
      const result = await callbacksStub.call(callbackToken, link);

      return result;
    } catch (error) {
      console.error("Error handling link callback:", error);
      throw error;
    }
  }
}
