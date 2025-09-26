import { type BuiltInTool } from "../../sdk";

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
 * Built-in tool for creating and managing persistent callback references.
 *
 * The CallbackTool enables agents and tools to create callback links that persist
 * across worker invocations and restarts. This is essential for webhook handlers,
 * scheduled operations, and user interaction flows that need to survive runtime
 * boundaries.
 *
 * **When to use callbacks:**
 * - Webhook handlers that need persistent function references
 * - Scheduled operations that run after worker timeouts
 * - User interaction links (ActivityLinkType.callback)
 * - Cross-tool communication that survives restarts
 *
 * **Security note:** Callbacks are hardcoded to target the tool's parent for security.
 *
 * @example
 * ```typescript
 * class MyTool extends Tool {
 *   private callback: CallbackTool;
 *
 *   constructor(tools: Tools) {
 *     super();
 *     this.callback = tools.get<CallbackTool>("callback");
 *   }
 *
 *   async setupWebhook() {
 *     const callback = await this.callback.create("handleWebhook", {
 *       webhookType: "calendar"
 *     });
 *
 *     // Use callback in webhook URL or activity link
 *     return `https://api.plot.day/webhook/${callback}`;
 *   }
 *
 *   async handleWebhook(data: any, context: any) {
 *     console.log("Webhook received:", data, context);
 *   }
 * }
 * ```
 */
export interface CallbackTool extends BuiltInTool {
  /**
   * Creates a persistent callback to the tool's parent.
   * Returns a callback token that can be used to call the callback later.
   *
   * @param functionName - The name of the function to call on the parent tool/agent
   * @param context - Optional context data to pass to the callback function
   * @returns Promise resolving to a callback token
   */
  create(functionName: string, context?: any): Promise<Callback>;

  /**
   * Executes a callback by its token.
   *
   * @param callback - The callback token returned by create()
   * @param args - Optional arguments to pass to the callback function
   * @returns Promise resolving to the callback result
   */
  call(callback: Callback, args?: any): Promise<any>;

  /**
   * Deletes a specific callback by its token.
   *
   * @param callback - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  delete(callback: Callback): Promise<void>;

  /**
   * Deletes all callbacks for the tool's parent.
   *
   * @returns Promise that resolves when all callbacks are deleted
   */
  deleteAll(): Promise<void>;
}
