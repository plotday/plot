import { ITool } from "..";
import type { CallbackMethods, NoFunctions, NonFunction } from "../utils/types";

// Re-export types for consumers
export type { CallbackMethods, NoFunctions, NonFunction };

/**
 * Represents a callback token for persistent function references.
 *
 * Callbacks enable tools and twists to create persistent references to functions
 * that can survive worker restarts and be invoked across different execution contexts.
 *
 * This is a branded string type to prevent mixing callback tokens with regular strings.
 *
 * @example
 * ```typescript
 * const callback = await this.callback(this.onCalendarSelected, "primary", "google");
 * ```
 */
export type Callback = string & { readonly __brand: "Callback" };

/**
 * Built-in tool for creating and managing persistent callback references.
 *
 * The Callbacks tool enables twists and tools to create callback links that persist
 * across worker invocations and restarts. This is essential for webhook handlers,
 * scheduled operations, and user interaction flows that need to survive runtime
 * boundaries.
 *
 * **Note:** Callback methods are also available directly on Twist and Tool classes
 * via `this.callback()`, `this.deleteCallback()`, `this.deleteAllCallbacks()`, and
 * `this.run()`. This is the recommended approach for most use cases.
 *
 * **When to use callbacks:**
 * - Webhook handlers that need persistent function references
 * - Scheduled operations that run after worker timeouts
 * - User interaction links (ActivityLinkType.callback)
 * - Cross-tool communication that survives restarts
 *
 * **Type Safety:**
 * Callbacks are fully type-safe - extraArgs are type-checked against the function signature.
 *
 * @example
 * ```typescript
 * class MyTool extends Tool {
 *   async setupWebhook() {
 *     // Using built-in callback method (recommended)
 *     const callback = await this.callback(this.handleWebhook, "calendar");
 *     return `https://api.plot.day/webhook/${callback}`;
 *   }
 *
 *   async handleWebhook(data: any, webhookType: string) {
 *     console.log("Webhook received:", data, webhookType);
 *   }
 * }
 * ```
 */
export abstract class Callbacks extends ITool {
  /**
   * Creates a persistent callback to a method on the current class.
   *
   * @param fn - The function to callback
   * @param extraArgs - Additional arguments to pass to the function (must be serializable)
   * @returns Promise resolving to a persistent callback token
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract create<Fn extends (...args: any[]) => any>(
    fn: Fn,
    ...extraArgs: Parameters<Fn>
  ): Promise<Callback>;

  /**
   * Creates a persistent callback to a function from the parent twist/tool.
   * Use this when the callback function is passed in from outside this class.
   *
   * @param fn - The function to callback
   * @param extraArgs - Additional arguments to pass to the function (must be serializable, validated at runtime)
   * @returns Promise resolving to a persistent callback token
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract createFromParent(
    fn: Function,
    ...extraArgs: any[]
  ): Promise<Callback>;

  /**
   * Deletes a specific callback by its token.
   *
   * @param callback - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract delete(callback: Callback): Promise<void>;

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
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract run<T = unknown>(callback: Callback, ...args: any[]): Promise<T>;
}
