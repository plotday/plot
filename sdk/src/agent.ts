import { type Activity, type Priority } from "./plot";
import type {
  Callback,
  CallbackContext,
  CallbackMethods,
  Callbacks,
} from "./tools/callbacks";
import type { Store } from "./tools/store";
import type { Tasks } from "./tools/tasks";

// Type utilities for extracting types from Init method
type PromiseValues<T> = {
  [K in keyof T]: T[K] extends Promise<infer U> ? U : T[K];
};

// Break down InferTools into intermediate steps to avoid deep recursion
type ExtractInitReturn<T> = T extends {
  Init: (...args: any[]) => infer R;
}
  ? R
  : never;

type ResolveInitTools<T> = PromiseValues<ExtractInitReturn<T>>;

type BuiltInTools<T> = {
  callbacks: Callbacks<T extends new (...args: any[]) => infer I ? I : any>;
  store: Store;
  tasks: Tasks;
} & {}; // Counter reset with intersection

// Note: Due to TypeScript limitations with self-referential generic types and static methods,
// this type may not properly infer tools in all cases. Use explicit type casts if needed.
type InferTools<T> = T extends {
  Init: (...args: any[]) => any;
  new (...args: any[]): any;
}
  ? ResolveInitTools<T> & BuiltInTools<T>
  : never;

type InferOptions<T> = T extends {
  Init: (tools: any, options?: infer O) => any;
}
  ? O
  : undefined;

type HasInit<TSelf> = {
  Init(tools: ToolBuilder, ...args: any[]): any;
  new (id: string, tools: any, ...args: any[]): any;
};

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
export abstract class Agent<TSelf extends HasInit<TSelf>> {
  constructor(
    protected id: string,
    protected tools: InferTools<TSelf>,
    protected options: InferOptions<TSelf>
  ) {}

  /**
   * Creates a persistent callback to a method on this agent.
   *
   * @param functionName - The name of the method to callback
   * @param context - Optional context data to pass to the callback
   * @returns Promise resolving to a callback token
   */
  protected async callback<
    K extends CallbackMethods<InstanceType<TSelf>> & string
  >(
    functionName: K,
    context?: CallbackContext<InstanceType<TSelf>, K>
  ): Promise<Callback> {
    return this.tools.callbacks.create(functionName, context);
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
      tagsAdded: Record<number, string[]>;
      tagsRemoved: Record<number, string[]>;
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

export type ToolConstructor<T extends ITool> =
  | (abstract new (id: string, tools: any, options?: any) => T)
  | (new (id: string, tools: any, options?: any) => T);

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
export abstract class Tool<TSelf extends HasInit<TSelf>> implements ITool {
  constructor(
    protected id: string,
    protected tools: InferTools<TSelf>,
    protected options: InferOptions<TSelf>
  ) {}

  /**
   * Creates a persistent callback to a method on this tool.
   *
   * @param functionName - The name of the method to callback
   * @param context - Optional context data to pass to the callback
   * @returns Promise resolving to a callback token
   */
  protected async callback<
    K extends CallbackMethods<InstanceType<TSelf>> & string
  >(
    functionName: K,
    context: CallbackContext<InstanceType<TSelf>, K>
  ): Promise<Callback> {
    return this.tools.callbacks.create(functionName, context);
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
}

/**
 * Interface for accessing tool dependencies.
 *
 * This interface provides type-safe access to tools that have been declared
 * as dependencies in the agent.json or tool.json configuration files.
 */
export interface ToolBuilder {
  /**
   * Initializes a tool instance by its class reference, returning a promise.
   *
   * @template T - The expected type of the tool
   * @template O - The options type expected by the tool's Init method
   * @param ToolClass - The tool class reference with Init method
   * @param options - Optional options to pass to the tool's Init method
   * @returns Promise resolving to the tool instance
   * @throws When the tool is not found or not properly configured
   */
  init<
    T extends ITool,
    O = T extends { Init: (tools: any, options?: infer Opt) => any }
      ? Opt
      : never
  >(
    ToolClass: ToolConstructor<T> & {
      Init: (tools: ToolBuilder, options?: O) => any;
    },
    options?: O
  ): Promise<T>;
}
