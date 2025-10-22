import { ITool, type Tools } from "..";

/**
 * Represents a callback token for persistent function references.
 *
 * Callbacks enable tools and agents to create persistent references to functions
 * that can survive worker restarts and be invoked across different execution contexts.
 *
 * This is a branded string type to prevent mixing callback tokens with regular strings.
 *
 * @example
 * ```typescript
 * const callback = await this.callback.create("onCalendarSelected", {
 *   calendarId: "primary",
 *   provider: "google"
 * });
 * ```
 */
export type Callback = string & { readonly __brand: "Callback" };

/**
 * Extracts method names from a type that match the callback signature.
 * Callback methods must accept (args: any, context?: any) and return Promise<any>
 * or accept (args: any) and return Promise<any>.
 */
export type CallbackMethods<T> = {
  [K in keyof T]: T[K] extends (args: any, context?: any) => Promise<any>
    ? K
    : never;
}[keyof T];

/**
 * Extracts the context parameter type for a specific callback method.
 * Returns undefined if the method doesn't accept a context parameter.
 */
export type CallbackContext<T, K extends keyof T> = T[K] extends (
  args: any,
  context?: infer C,
) => any
  ? C
  : undefined;

/**
 * Built-in tool for creating and managing persistent callback references.
 *
 * The CallbackTool enables agents and tools to create callback links that persist
 * across worker invocations and restarts. This is essential for webhook handlers,
 * scheduled operations, and user interaction flows that need to survive runtime
 * boundaries.
 *
 * **Note:** Callback methods are also available directly on Agent and Tool classes
 * via `this.callback()`, `this.deleteCallback()`, `this.deleteAllCallbacks()`, and
 * `this.callCallback()`. This is the recommended approach for most use cases.
 *
 * **When to use callbacks:**
 * - Webhook handlers that need persistent function references
 * - Scheduled operations that run after worker timeouts
 * - User interaction links (ActivityLinkType.callback)
 * - Cross-tool communication that survives restarts
 *
 * **Security note:** Callbacks are hardcoded to target the tool's parent for security.
 *
 * **Type Safety:**
 * For full type safety, cast the callback tool to include your agent/tool type:
 * `tools.get(CallbackTool) as CallbackTool<this>`
 * This enables autocomplete for method names and type-checked context parameters.
 *
 * @example
 * ```typescript
 * class MyTool extends Tool {
 *   async setupWebhook() {
 *     // Using built-in callback method (recommended)
 *     const callback = await this.callback("handleWebhook", {
 *       webhookType: "calendar"
 *     });
 *
 *     // Use callback in webhook URL or activity link
 *     return `https://api.plot.day/webhook/${callback}`;
 *   }
 *
 *   async handleWebhook(data: any, context?: { webhookType: string }) {
 *     console.log("Webhook received:", data, context);
 *   }
 * }
 * ```
 */
export abstract class CallbackTool<TParent = any> extends ITool {
  /**
   * Creates a persistent callback to the tool's parent.
   * Returns a callback token that can be used to call the callback later.
   *
   * @param functionName - The name of the function to call on the parent tool/agent
   * @param context - Optional context data to pass to the callback function (type-checked when TParent is specified)
   * @returns Promise resolving to a callback token
   */
  abstract create<K extends CallbackMethods<TParent>>(
    _functionName: K,
    _context?: CallbackContext<TParent, K>,
  ): Promise<Callback>;

  /**
   * Deletes a specific callback by its token.
   *
   * @param callback - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  abstract delete(_callback: Callback): Promise<void>;

  /**
   * Deletes all callbacks for the tool's parent.
   *
   * @returns Promise that resolves when all callbacks are deleted
   */
  abstract deleteAll(): Promise<void>;

  /**
   * Executes a callback by its token.
   *
   * @param callback - The callback token returned by create()
   * @param args - Optional arguments to pass to the callback function
   * @returns Promise resolving to the callback result
   */
  abstract callCallback(_callback: Callback, _args?: any): Promise<any>;
}
