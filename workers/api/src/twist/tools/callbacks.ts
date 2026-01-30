import { type ActivityLink, ActivityLinkType } from "@plotday/twister/plot";
import type {
  Callback,
  Callbacks as ICallbackTool,
} from "@plotday/twister/tools/callbacks";

import { type TwistEnvironment } from "../../env";
import { CallbacksState } from "../../state/callbacks";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc, getRpcFunctionName } from "../../utils/rpc";
import { Tool } from "./tool";

export * from "@plotday/twister/tools/callbacks";

export class Callbacks extends Tool implements ICallbackTool {
  private callbacks: DurableObjectStub<CallbacksState>;
  private priorityTwistId: string;
  private twistId: string;
  private environment: TwistEnvironment;
  private path: string[];

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
  }) {
    super();
    this.callbacks = Callbacks.GetStub(
      options.callbacks,
      options.priorityTwistId
    );
    this.priorityTwistId = options.priorityTwistId;
    this.twistId = options.twistId;
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
      priorityTwistId: this.priorityTwistId,
      path: this.path,
      functionName,
      extraArgs,
    });
    // Dispose RPC result (token is a string primitive, safely ignored)
    disposeRpc(token);

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
      priorityTwistId: this.priorityTwistId,
      path: this.path.slice(0, -1),
      functionName,
      extraArgs,
    });
    // Dispose RPC result (token is a string primitive, safely ignored)
    disposeRpc(token);

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
    const result = await this.callbacks.callCallback(callback, ...(args ?? []));
    disposeRpc(result);
    return result;
  }

  async delete(callback: Callback): Promise<void> {
    const result = await this.callbacks.delete(callback);
    disposeRpc(result);
  }

  async deleteAll(): Promise<void> {
    const result = await this.callbacks.deleteAll({
      priorityTwistId: this.priorityTwistId,
      path: this.path,
    });
    disposeRpc(result);
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

      const callbackToken = link.callback;
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
      const logger = createLogger();
      logger.error("Error handling link callback", error as Error, { callback_token: token });
      throw error;
    }
  }
}
