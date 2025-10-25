import { type Activity, type ActorId, type Priority, type Tag } from "./plot";
import type { Callback } from "./tools/callbacks";
import type {
  CallbackMethods,
  HasInit,
  InferOptions,
  InferTools,
  NoFunctions,
  ToolBuilder,
} from "./utils/types";

export type { ToolBuilder };

/**
 * Base class for all agents.
 *
 * Agents are activated in a Plot priority and have access to that priority and all
 * its descendants.
 *
 * Override method to handle events.
 *
 * @example
 * ```typescript
 * class FlatteringAgent extends Agent<FlatteringAgent> {
 *   static Init(tools: ToolBuilder, options?: { greeting: string }) {
 *     return {
 *       plot: tools.init(Plot, PLOT_OPTIONS),
 *     };
 *   }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Initialize agent for the given priority
 *     await this.tools.plot.createActivity({
 *       type: ActivityType.Note,
 *       note: this.options.greeting || "Hello, good looking!",
 *     });
 *   }
 *
 *   async activity(activity: Activity) {
 *     // Process new activity
 *   }
 * }
 * ```
 */
export abstract class Agent<TSelf extends HasInit> {
  constructor(
    protected id: string,
    protected tools: InferTools<TSelf>,
    protected options: InferOptions<TSelf>
  ) {}

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
  protected async callback<
    K extends CallbackMethods<InstanceType<TSelf>>,
    TMethod extends InstanceType<TSelf>[K] = InstanceType<TSelf>[K]
  >(
    fn: TMethod,
    ...extraArgs: TMethod extends (arg: any, ...rest: infer R) => any
      ? NoFunctions<R>
      : []
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
   * @param _priority - The priority context containing the priority ID
   * @returns Promise that resolves when activation is complete
   */
  activate(_priority: Pick<Priority, "id">): Promise<void> {
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
   * Called when an activity needs to be processed by this agent.
   *
   * This method is invoked when activities are routed to this agent,
   * either through explicit assignment or through filtering rules.
   *
   * @param _activity - The activity to process
   * @param _changes - Optional changes object containing the previous version of the activity for updates,
   *                   along with tags that were added or removed
   * @returns Promise that resolves when processing is complete
   */
  activity(
    _activity: Activity,
    _changes?: {
      previous: Activity;
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
    }
  ): Promise<void> {
    return Promise.resolve();
  }
}

/**
 * Interface for tools. Tools should extend Tool. Several built-in tools
 * implement this interface directly since they're securely proxied
 * outside the agent runtime.
 */
export abstract class ITool {}

/**
 * Base class for regular tools.
 *
 * Regular tools.tasks in isolation and can only access other tools declared
 * in their tool.json dependencies. They are ideal for external API integrations
 * and reusable functionality that doesn't require Plot's internal infrastructure.
 *
 * @example
 * ```typescript
 * class GoogleCalendarTool extends Tool<GoogleCalendarTool> {
 *   static Init(tools: ToolBuilder, options?: { clientId: string }) {
 *     return {
 *       auth: tools.init(Integrations, AUTH_OPTIONS),
 *       network: tools.init(Network, NETWORK_OPTIONS),
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
export abstract class Tool<TSelf extends HasInit> implements ITool {
  constructor(
    protected id: string,
    protected tools: InferTools<TSelf>,
    protected options: InferOptions<TSelf>
  ) {}

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
  protected async callback<
    K extends CallbackMethods<InstanceType<TSelf>>,
    TMethod extends InstanceType<TSelf>[K] = InstanceType<TSelf>[K]
  >(
    fn: TMethod,
    ...extraArgs: TMethod extends (arg: any, ...rest: infer R) => any
      ? NoFunctions<R>
      : []
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
   * @param _priority - The priority context containing the priority ID
   * @returns Promise that resolves when pre-activation is complete
   */
  preActivate(_priority: Priority): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called after the agent's activate method, starting from the top-level tools.
   *
   * This method is called in reverse order, with top-level tools being called
   * first, then cascading down to the deepest dependencies.
   *
   * @param _priority - The priority context containing the priority ID
   * @returns Promise that resolves when post-activation is complete
   */
  postActivate(_priority: Priority): Promise<void> {
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
}
