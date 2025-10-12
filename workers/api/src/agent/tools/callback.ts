import { type ActivityLink, ActivityLinkType } from "@plotday/sdk";
import type {
  Callback,
  CallbackTool as ICallbackTool,
} from "@plotday/sdk/tools/callback";

import { Callbacks } from "../../state/callbacks";
import { Tool } from "./tool";

export class CallbackTool extends Tool implements ICallbackTool {
  private callbacks: DurableObjectStub<Callbacks>;
  private priorityAgentId: string;
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
    path,
  }: {
    callbacks: DurableObjectNamespace<Callbacks>;
    priorityAgentId: string;
    path: string[];
  }) {
    super();
    this.callbacks = CallbackTool.GetStub(callbacks, priorityAgentId);
    this.priorityAgentId = priorityAgentId;
    // Remove this tool
    this.path = path.slice(0, -1);
  }

  async create(functionName: string, context?: any): Promise<Callback> {
    const token = await this.callbacks.create({
      priorityAgentId: this.priorityAgentId,
      path: this.path,
      functionName,
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
