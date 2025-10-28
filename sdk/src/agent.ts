import { type Priority } from "./plot";
import { type ITool } from "./tool";
import type { Callback } from "./tools/callbacks";
import type { InferTools, ToolBuilder, ToolShed } from "./utils/types";

/**
 * Base class for all agents.
 *
 * Agents are activated in a Plot priority and have access to that priority and all
 * its descendants.
 *
 * Override build() to declare tool dependencies and lifecycle methods to handle events.
 *
 * @example
 * ```typescript
 * class FlatteringAgent extends Agent<FlatteringAgent> {
 *   build(build: ToolBuilder) {
 *     return {
 *       plot: build(Plot),
 *     };
 *   }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Initialize agent for the given priority
 *     await this.tools.plot.createActivity({
 *       type: ActivityType.Note,
 *       note: "Hello, good looking!",
 *     });
 *   }
 * }
 * ```
 */
export abstract class Agent<TSelf> {
  constructor(protected id: string, private toolShed: ToolShed) {}

  /**
   * Gets the initialized tools for this agent.
   * @throws Error if called before initialization is complete
   */
  protected get tools(): InferTools<TSelf> {
    return this.toolShed.getTools<InferTools<TSelf>>();
  }

  /**
   * Declares tool dependencies for this agent.
   * Return an object mapping tool names to build() promises.
   *
   * @param build - The build function to use for declaring dependencies
   * @returns Object mapping tool names to tool promises
   *
   * @example
   * ```typescript
   * build(build: ToolBuilder) {
   *   return {
   *     plot: build(Plot),
   *     calendar: build(GoogleCalendar, { apiKey: "..." }),
   *   };
   * }
   * ```
   */
  abstract build(build: ToolBuilder): Record<string, Promise<ITool>>;

  /**
   * Creates a persistent callback to a method on this agent.
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
    return this.tools.callbacks.create(fn as any, ...extraArgs);
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
   * Deletes all callbacks for this agent.
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
  protected async run(token: Callback, ...args: []): Promise<any> {
    return this.tools.callbacks.run(token, ...args);
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
   * Removes all keys from this agent's storage.
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
   * Cancels all scheduled executions for this agent.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  protected async cancelAllTasks(): Promise<void> {
    return this.tools.tasks.cancelAllTasks();
  }

  /**
   * Called when the agent is activated for a specific priority.
   *
   * This method should contain initialization logic such as setting up
   * initial activities, configuring webhooks, or establishing external connections.
   *
   * @param priority - The priority context containing the priority ID
   * @returns Promise that resolves when activation is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  activate(priority: Pick<Priority, "id">): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a new version of the agent is deployed to an existing priority.
   *
   * This method should contain migration logic for updating old data structures
   * or setting up new resources that weren't needed by the previous version.
   * It is called with the new version for each active priorityAgent.
   *
   * @returns Promise that resolves when upgrade is complete
   */
  upgrade(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when the agent is removed from a priority.
   *
   * This method should contain cleanup logic such as removing webhooks,
   * cleaning up external resources, or performing final data operations.
   *
   * @returns Promise that resolves when deactivation is complete
   */
  deactivate(): Promise<void> {
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
