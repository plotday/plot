import { type Priority } from "./plot";
import type { Callback } from "./tools/callbacks";
import type {
  InferOptions,
  InferTools,
  ToolBuilder,
  ToolShed,
} from "./utils/types";

export type { ToolBuilder };

/**
 * Abstrtact parent for both built-in tools and regular Tools.
 * Regular tools extend Tool.
 */
export abstract class ITool {}

/**
 * Base class for regular tools.
 *
 * Regular tools run in isolation and can only access other tools declared
 * in their build method. They are ideal for external API integrations
 * and reusable functionality that doesn't require Plot's internal infrastructure.
 *
 * @example
 * ```typescript
 * class GoogleCalendarTool extends Tool<GoogleCalendarTool> {
 *   constructor(id: string, options: { clientId: string }) {
 *     super(id, options);
 *   }
 *
 *   build(tools: ToolBuilder) {
 *     return {
 *       auth: tools.build(Integrations),
 *       network: tools.build(Network),
 *     };
 *   }
 *
 *   async getCalendars() {
 *     const token = await this.tools.auth.get(...);
 *     // Implementation
 *   }
 * }
 * ```
 */
export abstract class Tool<TSelf> implements ITool {
  constructor(
    protected id: string,
    protected options: InferOptions<TSelf>,
    private toolShed: ToolShed
  ) {}

  /**
   * Gets the initialized tools for this tool.
   * @throws Error if called before initialization is complete
   */
  protected get tools() {
    return this.toolShed.getTools<InferTools<TSelf>>();
  }

  /**
   * Declares tool dependencies for this tool.
   * Return an object mapping tool names to build() promises.
   * Default implementation returns empty object (no custom tools).
   *
   * @param build - The build function to use for declaring dependencies
   * @returns Object mapping tool names to tool promises
   *
   * @example
   * ```typescript
   * build(build: ToolBuilder) {
   *   return {
   *     network: build(Network, { urls: ["https://api.example.com/*"] }),
   *   };
   * }
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  build(build: ToolBuilder): Record<string, Promise<ITool>> {
    return {};
  }

  /**
   * Creates a persistent callback to a method on this tool.
   *
   * ExtraArgs are strongly typed to match the method's signature after the first argument.
   *
   * @param fn - The method to callback
   * @param extraArgs - Additional arguments to pass (type-checked, must be serializable)
   * @returns Promise resolving to a persistent callback token
   *
   * @example
   * ```typescript
   * const callback = await this.callback(this.onWebhook, "calendar", 123);
   * ```
   */
  protected async callback(
    fn: Function,
    ...extraArgs: any[]
  ): Promise<Callback> {
    return this.tools.callbacks.create(fn, ...extraArgs);
  }

  /**
   * Deletes a specific callback by its token.
   *
   * @param token - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  protected async deleteCallback(token: Callback): Promise<void> {
    return this.tools.callbacks.delete(token);
  }

  /**
   * Deletes all callbacks for this tool.
   *
   * @returns Promise that resolves when all callbacks are deleted
   */
  protected async deleteAllCallbacks(): Promise<void> {
    return this.tools.callbacks.deleteAll();
  }

  /**
   * Executes a callback by its token.
   *
   * @param token - The callback token to execute
   * @param args - Optional arguments to pass to the callback
   * @returns Promise resolving to the callback result
   */
  protected async run(token: Callback, args?: any): Promise<any> {
    return this.tools.callbacks.run(token, args);
  }

  /**
   * Retrieves a value from persistent storage by key.
   *
   * @template T - The expected type of the stored value
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  protected async get<T>(key: string): Promise<T | null> {
    return this.tools.store.get(key);
  }

  /**
   * Stores a value in persistent storage.
   *
   * **Important**: Values must be JSON-serializable. Functions, Symbols, and undefined values
   * cannot be stored directly.
   *
   * **For function references**: Use callbacks instead of storing functions directly.
   *
   * @example
   * ```typescript
   * // ❌ WRONG: Cannot store functions directly
   * await this.set("handler", this.myHandler);
   *
   * // ✅ CORRECT: Create a callback token first
   * const token = await this.callback(this.myHandler, "arg1", "arg2");
   * await this.set("handler_token", token);
   *
   * // Later, execute the callback
   * const token = await this.get<string>("handler_token");
   * await this.run(token, args);
   * ```
   *
   * @template T - The type of value being stored
   * @param key - The storage key to use
   * @param value - The value to store (must be JSON-serializable)
   * @returns Promise that resolves when the value is stored
   */
  protected async set<T>(key: string, value: T): Promise<void> {
    return this.tools.store.set(key, value);
  }

  /**
   * Removes a specific key from persistent storage.
   *
   * @param key - The storage key to remove
   * @returns Promise that resolves when the key is removed
   */
  protected async clear(key: string): Promise<void> {
    return this.tools.store.clear(key);
  }

  /**
   * Removes all keys from this tool's storage.
   *
   * @returns Promise that resolves when all keys are removed
   */
  protected async clearAll(): Promise<void> {
    return this.tools.store.clearAll();
  }

  /**
   * Queues a callback to execute in a separate worker context.
   *
   * @param callback - The callback token created with `this.callback()`
   * @param options - Optional configuration for the execution
   * @param options.runAt - If provided, schedules execution at this time; otherwise runs immediately
   * @returns Promise resolving to a cancellation token (only for scheduled executions)
   */
  protected async runTask(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void> {
    return this.tools.tasks.runTask(callback, options);
  }

  /**
   * Cancels a previously scheduled execution.
   *
   * @param token - The cancellation token returned by runTask() with runAt option
   * @returns Promise that resolves when the cancellation is processed
   */
  protected async cancelTask(token: string): Promise<void> {
    return this.tools.tasks.cancelTask(token);
  }

  /**
   * Cancels all scheduled executions for this tool.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  protected async cancelAllTasks(): Promise<void> {
    return this.tools.tasks.cancelAllTasks();
  }

  /**
   * Called before the agent's activate method, starting from the deepest tool dependencies.
   *
   * This method is called in a depth-first manner, with the deepest dependencies
   * being called first, bubbling up to the top-level tools before the agent's
   * activate method is called.
   *
   * @param priority - The priority context containing the priority ID
   * @returns Promise that resolves when pre-activation is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  preActivate(priority: Priority): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called after the agent's activate method, starting from the top-level tools.
   *
   * This method is called in reverse order, with top-level tools being called
   * first, then cascading down to the deepest dependencies.
   *
   * @param priority - The priority context containing the priority ID
   * @returns Promise that resolves when post-activation is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  postActivate(priority: Priority): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called before the agent's upgrade method, starting from the deepest tool dependencies.
   *
   * This method is called in a depth-first manner, with the deepest dependencies
   * being called first, bubbling up to the top-level tools before the agent's
   * upgrade method is called.
   *
   * @returns Promise that resolves when pre-upgrade is complete
   */
  preUpgrade(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called after the agent's upgrade method, starting from the top-level tools.
   *
   * This method is called in reverse order, with top-level tools being called
   * first, then cascading down to the deepest dependencies.
   *
   * @returns Promise that resolves when post-upgrade is complete
   */
  postUpgrade(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called before the agent's deactivate method, starting from the deepest tool dependencies.
   *
   * This method is called in a depth-first manner, with the deepest dependencies
   * being called first, bubbling up to the top-level tools before the agent's
   * deactivate method is called.
   *
   * @returns Promise that resolves when pre-deactivation is complete
   */
  preDeactivate(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called after the agent's deactivate method, starting from the top-level tools.
   *
   * This method is called in reverse order, with top-level tools being called
   * first, then cascading down to the deepest dependencies.
   *
   * @returns Promise that resolves when post-deactivation is complete
   */
  postDeactivate(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Waits for tool initialization to complete.
   * Called automatically by the entrypoint before lifecycle methods.
   * @internal
   */
  async waitForReady(): Promise<void> {
    await this.toolShed.waitForReady();
  }
}
