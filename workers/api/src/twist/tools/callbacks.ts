import { type Action, ActionType } from "@plotday/twister/plot";
import type {
  Callback,
  Callbacks as ICallbackTool,
} from "@plotday/twister/tools/callbacks";

import { type TwistEnvironment } from "../../env";
import { CallbacksState, type ResolvedCallback } from "../../state/callbacks";
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
    disposeRpc(fn);
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
    return token as Callback;
  }

  async createFromParent(fn: Function, ...extraArgs: any[]): Promise<Callback> {
    const functionName = await getRpcFunctionName(fn);
    disposeRpc(fn);
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

  /**
   * Resolves callback metadata without executing it.
   *
   * This is the fast path used by the twist worker's MODULE code to avoid
   * the expensive full-reconstruction path in callCallback(). Instead of
   * constructing a new twist (Supabase queries, module loading, permission
   * checks, tool tree rebuild), the twist worker calls resolve() to get
   * the callback metadata, then executes the function directly on its
   * already-constructed tool tree.
   *
   * The interception happens in entrypoint.ts MODULE: ToolShed.waitForReady()
   * wraps callbacks.run() to call resolve() + local execution instead.
   *
   * @see {@link CallbacksState.resolve} for the DO implementation
   * @see entrypoint.ts MODULE ToolShed.waitForReady() for the interception
   */
  async resolve(callback: Callback): Promise<ResolvedCallback | null> {
    const result = await this.callbacks.resolve(callback);
    if (!result) return result;
    const resolved = {
      ...result,
      path: [...result.path],
      extraArgs: result.extraArgs ? [...result.extraArgs] : undefined,
    };
    return resolved;
  }

  /**
   * Executes a callback by its token.
   *
   * NOTE: When called from within a twist worker, this method is intercepted
   * by the MODULE code in entrypoint.ts. The interceptor calls resolve()
   * instead, then executes the callback locally on the already-constructed
   * tool tree — avoiding the full twist reconstruction that callCallback()
   * performs. This method only runs as a fallback if local resolution fails.
   *
   * @see entrypoint.ts MODULE ToolShed.waitForReady() for the interception
   */
  async run(callback: Callback, ...args: any[]): Promise<any> {
    const result = await this.callbacks.callCallback(callback, ...(args ?? []));
    return result;
  }

  async delete(callback: Callback): Promise<void> {
    await this.callbacks.delete(callback);
  }

  async deleteAll(): Promise<void> {
    await this.callbacks.deleteAll({
      priorityTwistId: this.priorityTwistId,
      path: this.path,
    });
  }

  /**
   * Static method to handle activity link callbacks from API endpoints
   */
  static async HandleActionCallback(
    callbacks: DurableObjectNamespace<CallbacksState>,
    token: string,
    action: Action
  ): Promise<any> {
    try {
      // Extract callback token from the action
      if (action.type !== ActionType.callback) {
        throw new Error("Action is not a callback type");
      }

      const callbackToken = action.callback;
      if (!callbackToken) {
        throw new Error("No callback token found in thread action");
      }

      if (callbackToken !== token) {
        throw new Error("Callback token mismatch");
      }

      // Execute the callback with the full thread action as argument
      const result = await CallbacksState.CallCallback(
        callbacks,
        callbackToken,
        action
      );

      return result;
    } catch (error) {
      const logger = createLogger();
      logger.error("Error handling action callback", error as Error, { callback_token: token });
      throw error;
    }
  }

  /** @deprecated Use HandleActionCallback */
  static HandleLinkCallback = Callbacks.HandleActionCallback;
}
