import { type Activity, type Priority } from "./plot";
import type {
  Callback,
  CallbackContext,
  CallbackMethods,
} from "./tools/callback";

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
 *  private plot: Plot;
 *
 *  constructor(id: string, tools: Tools) {
 *    super(id, tools);
 *    this.plot = tools.get(Plot);
 *  }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Initialize agent for the given priority
 *     await this.plot.createActivity({
 *      type: ActivityType.Note,
 *      note: "Hello, good looking!",
 *    });
 *   }
 *
 *   async activity(activity: Activity) {
 *     // Process new activity
 *   }
 * }
 * ```
 */
export abstract class Agent<TSelf = any> {
  protected id: string;
  protected tools: Tools;

  constructor(id: string, tools: Tools) {
    this.id = id;
    this.tools = tools;
  }

  /**
   * Creates a persistent callback to a method on this agent.
   *
   * @param functionName - The name of the method to callback
   * @param context - Optional context data to pass to the callback
   * @returns Promise resolving to a callback token
   */
  protected async callback<K extends CallbackMethods<TSelf>>(
    functionName: K,
    context?: CallbackContext<TSelf, K>
  ): Promise<Callback> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.create(functionName, context);
  }

  /**
   * Deletes a specific callback by its token.
   *
   * @param token - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  protected async deleteCallback(token: Callback): Promise<void> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.delete(token);
  }

  /**
   * Deletes all callbacks for this agent.
   *
   * @returns Promise that resolves when all callbacks are deleted
   */
  protected async deleteAllCallbacks(): Promise<void> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.deleteAll();
  }

  /**
   * Executes a callback by its token.
   *
   * @param token - The callback token to execute
   * @param args - Optional arguments to pass to the callback
   * @returns Promise resolving to the callback result
   */
  protected async call(token: Callback, args?: any): Promise<any> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.call(token, args);
  }

  /**
   * Retrieves a value from persistent storage by key.
   *
   * @template T - The expected type of the stored value
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  protected async get<T>(key: string): Promise<T | null> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.get<T>(key);
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
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.set(key, value);
  }

  /**
   * Removes a specific key from persistent storage.
   *
   * @param key - The storage key to remove
   * @returns Promise that resolves when the key is removed
   */
  protected async clear(key: string): Promise<void> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.clear(key);
  }

  /**
   * Removes all keys from this agent's storage.
   *
   * @returns Promise that resolves when all keys are removed
   */
  protected async clearAll(): Promise<void> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.clearAll();
  }

  /**
   * Queues a callback to execute in a separate worker context.
   *
   * @param callback - The callback token created with `this.callback()`
   * @param options - Optional configuration for the execution
   * @param options.runAt - If provided, schedules execution at this time; otherwise runs immediately
   * @returns Promise resolving to a cancellation token (only for scheduled executions)
   */
  protected async run(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.run(callback, options);
  }

  /**
   * Cancels a previously scheduled execution.
   *
   * @param token - The cancellation token returned by run() with runAt option
   * @returns Promise that resolves when the cancellation is processed
   */
  protected async cancel(token: string): Promise<void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.cancel(token);
  }

  /**
   * Cancels all scheduled executions for this agent.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  protected async cancelAll(): Promise<void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.cancelAll();
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

export type ToolConstructor<T extends ITool> = (abstract new (id: string, tools: Tools) => T) | (new (id: string, tools: Tools) => T);

/**
 * Base class for regular tools.
 *
 * Regular tools run in isolation and can only access other tools declared
 * in their tool.json dependencies. They are ideal for external API integrations
 * and reusable functionality that doesn't require Plot's internal infrastructure.
 *
 * @example
 * ```typescript
 * class GoogleCalendarTool extends Tool<GoogleCalendarTool> {
 *   constructor(id: string, tools: Tools) {
 *     super(id, tools);
 *     this.auth = tools.get(Auth);
 *   }
 *
 *   async getCalendars() {
 *     // Implementation
 *   }
 * }
 * ```
 */
export abstract class Tool<TSelf = any> implements ITool {
  protected id: string;
  protected tools: Tools;

  constructor(id: string, tools: Tools) {
    this.id = id;
    this.tools = tools;
  }

  /**
   * Creates a persistent callback to a method on this tool.
   *
   * @param functionName - The name of the method to callback
   * @param context - Optional context data to pass to the callback
   * @returns Promise resolving to a callback token
   */
  protected async callback<K extends CallbackMethods<TSelf>>(
    functionName: K,
    context?: CallbackContext<TSelf, K>
  ): Promise<Callback> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.create(functionName, context);
  }

  /**
   * Deletes a specific callback by its token.
   *
   * @param token - The callback token to delete
   * @returns Promise that resolves when the callback is deleted
   */
  protected async deleteCallback(token: Callback): Promise<void> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.delete(token);
  }

  /**
   * Deletes all callbacks for this tool.
   *
   * @returns Promise that resolves when all callbacks are deleted
   */
  protected async deleteAllCallbacks(): Promise<void> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.deleteAll();
  }

  /**
   * Executes a callback by its token.
   *
   * @param token - The callback token to execute
   * @param args - Optional arguments to pass to the callback
   * @returns Promise resolving to the callback result
   */
  protected async call(token: Callback, args?: any): Promise<any> {
    const { CallbackTool } = await import("./tools/callback");
    const callbackTool = this.tools.get(CallbackTool) as any;
    return callbackTool.call(token, args);
  }

  /**
   * Retrieves a value from persistent storage by key.
   *
   * @template T - The expected type of the stored value
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  protected async get<T>(key: string): Promise<T | null> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.get<T>(key);
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
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.set(key, value);
  }

  /**
   * Removes a specific key from persistent storage.
   *
   * @param key - The storage key to remove
   * @returns Promise that resolves when the key is removed
   */
  protected async clear(key: string): Promise<void> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.clear(key);
  }

  /**
   * Removes all keys from this tool's storage.
   *
   * @returns Promise that resolves when all keys are removed
   */
  protected async clearAll(): Promise<void> {
    const { Store } = await import("./tools/store");
    const store = this.tools.get(Store);
    return store.clearAll();
  }

  /**
   * Queues a callback to execute in a separate worker context.
   *
   * @param callback - The callback token created with `this.callback()`
   * @param options - Optional configuration for the execution
   * @param options.runAt - If provided, schedules execution at this time; otherwise runs immediately
   * @returns Promise resolving to a cancellation token (only for scheduled executions)
   */
  protected async run(
    callback: Callback,
    options?: { runAt?: Date }
  ): Promise<string | void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.run(callback, options);
  }

  /**
   * Cancels a previously scheduled execution.
   *
   * @param token - The cancellation token returned by run() with runAt option
   * @returns Promise that resolves when the cancellation is processed
   */
  protected async cancel(token: string): Promise<void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.cancel(token);
  }

  /**
   * Cancels all scheduled executions for this tool.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  protected async cancelAll(): Promise<void> {
    const { Run } = await import("./tools/run");
    const runTool = this.tools.get(Run);
    return runTool.cancelAll();
  }
}

/**
 * Interface for accessing tool dependencies.
 *
 * This interface provides type-safe access to tools that have been declared
 * as dependencies in the agent.json or tool.json configuration files.
 */
export interface Tools {
  /**
   * Retrieves a tool instance by its class reference.
   *
   * @template T - The expected type of the tool
   * @param ToolClass - The tool class reference
   * @returns The tool instance
   * @throws When the tool is not found or not properly configured
   */
  get<T extends ITool>(ToolClass: ToolConstructor<T>): T;
}
