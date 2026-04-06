import { type Action, type Actor, type ActorId, type Link, type Note, type Priority, type Thread, Uuid } from "./plot";
import type { Tag } from "./tag";
import { type ITool } from "./tool";
import type { Callback } from "./tools/callbacks";
import type { Serializable } from "./utils/serializable";
import type { InferTools, ToolBuilder, ToolShed } from "./utils/types";

/**
 * Base class for all twists.
 *
 * Twists are activated in a Plot priority and have access to that priority and all
 * its descendants.
 *
 * Override build() to declare tool dependencies and lifecycle methods to handle events.
 *
 * @example
 * ```typescript
 * class FlatteringTwist extends Twist<FlatteringTwist> {
 *   build(build: ToolBuilder) {
 *     return {
 *       plot: build(Plot),
 *     };
 *   }
 *
 *   async activate(priority: Pick<Priority, "id">) {
 *     // Initialize twist for the given priority
 *     await this.tools.plot.createThread({
 *       title: "Hello, good looking!",
 *     });
 *   }
 * }
 * ```
 */
export abstract class Twist<TSelf> {
  constructor(protected id: Uuid, private toolShed: ToolShed) {}

  /**
   * Gets the initialized tools for this twist.
   * @throws Error if called before initialization is complete
   */
  protected get tools(): InferTools<TSelf> {
    return this.toolShed.getTools<InferTools<TSelf>>();
  }

  /**
   * Declares tool dependencies for this twist.
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
   * Creates a persistent callback to a method on this twist.
   *
   * ExtraArgs are strongly typed to match the method's signature. They must be serializable.
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
  protected callback<
    TArgs extends Serializable[],
    Fn extends (...args: TArgs) => any
  >(fn: Fn, ...extraArgs: TArgs): Promise<Callback>;
  // Overload when caller provides the first argument
  protected callback<
    TArgs extends Serializable[],
    Fn extends (arg1: any, ...extraArgs: TArgs) => any
  >(fn: Fn, ...extraArgs: TArgs): Promise<Callback>;
  protected async callback<
    TArgs extends Serializable[],
    Fn extends (...args: any[]) => any
  >(fn: Fn, ...extraArgs: TArgs): Promise<Callback> {
    return this.tools.callbacks.create(fn, ...extraArgs);
  }

  /**
   * Like callback(), but for an Action, which receives the action as the first argument.
   *
   * @param fn - The method to callback
   * @param extraArgs - Additional arguments to pass after the action
   * @returns Promise resolving to a persistent callback token
   *
   * @example
   * ```typescript
   * const callback = await this.actionCallback(this.doSomething, 123);
   * const action: Action = {
   *    type: ActionType.callback,
   *    title: "Do Something",
   *    callback,
   * };
   * ```
   */
  protected async actionCallback<
    TArgs extends Serializable[],
    Fn extends (action: Action, ...extraArgs: TArgs) => any
  >(fn: Fn, ...extraArgs: TArgs): Promise<Callback> {
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
   * Deletes all callbacks for this twist.
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
   * Values are automatically deserialized using SuperJSON, which
   * properly restores Date objects, Maps, Sets, and other complex types.
   *
   * @template T - The expected type of the stored value (must be Serializable)
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  protected async get<T extends import("./index").Serializable>(
    key: string
  ): Promise<T | null> {
    return this.tools.store.get(key);
  }

  /**
   * Stores a value in persistent storage.
   *
   * The value will be serialized using SuperJSON and stored persistently.
   * SuperJSON automatically handles Date objects, Maps, Sets, undefined values,
   * and other complex types that standard JSON doesn't support.
   *
   * **Important**: Functions and Symbols cannot be stored.
   * **For function references**: Use callbacks instead of storing functions directly.
   *
   * @example
   * ```typescript
   * // ✅ Date objects are preserved
   * await this.set("sync_state", {
   *   lastSync: new Date(),
   *   minDate: new Date(2024, 0, 1)
   * });
   *
   * // ✅ undefined is now supported
   * await this.set("data", { name: "test", optional: undefined });
   *
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
   * @template T - The type of value being stored (must be Serializable)
   * @param key - The storage key to use
   * @param value - The value to store (must be SuperJSON-serializable)
   * @returns Promise that resolves when the value is stored
   */
  protected async set<T extends import("./index").Serializable>(
    key: string,
    value: T
  ): Promise<void> {
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
   * Removes all keys from this twist's storage.
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
   * Cancels all scheduled executions for this twist.
   *
   * @returns Promise that resolves when all cancellations are processed
   */
  protected async cancelAllTasks(): Promise<void> {
    return this.tools.tasks.cancelAllTasks();
  }

  /**
   * Called when the twist is activated for a specific priority.
   *
   * This method should contain initialization logic such as setting up
   * initial threads, configuring webhooks, or establishing external connections.
   *
   * @param priority - The priority context containing the priority ID
   * @param context - Optional context containing the actor who triggered activation
   * @returns Promise that resolves when activation is complete
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  activate(priority: Pick<Priority, "id">, context?: { actor: Actor }): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a new version of the twist is deployed to an existing priority.
   *
   * This method should contain migration logic for updating old data structures
   * or setting up new resources that weren't needed by the previous version.
   * It is called with the new version for each active priorityTwist.
   *
   * @returns Promise that resolves when upgrade is complete
   */
  upgrade(): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when the twist's options configuration changes.
   *
   * Override to react to option changes, e.g. archiving items when a sync
   * type is toggled off, or starting sync when a type is toggled on.
   *
   * @param oldOptions - The previously resolved options
   * @param newOptions - The newly resolved options
   * @returns Promise that resolves when the change is handled
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onOptionsChanged(
    oldOptions: Record<string, any>,
    newOptions: Record<string, any>
  ): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when the twist is removed from a priority.
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
   * Called when a thread created by this twist is updated.
   * Override to implement two-way sync with an external system.
   *
   * @param thread - The updated thread
   * @param changes - Tag additions and removals on the thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onThreadUpdated(
    thread: Thread,
    changes: {
      tagsAdded: Record<Tag, ActorId[]>;
      tagsRemoved: Record<Tag, ActorId[]>;
    }
  ): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a note is created on a thread created by this twist.
   * Override to implement two-way sync (e.g. syncing notes as comments).
   *
   * Notes created by the twist itself are filtered out to prevent loops.
   *
   * Returning a string sets the note's `key` for future upsert matching,
   * linking the Plot note to its external counterpart so that subsequent
   * syncs (reactions, edits) update the existing note instead of creating duplicates.
   *
   * @param note - The newly created note
   * @returns Optional note key for external deduplication
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onNoteCreated(note: Note, ...args: any[]): Promise<string | void> {
    return Promise.resolve();
  }

  /**
   * Called when a link is created in a connected source channel.
   * Requires `link: true` in Plot options.
   *
   * @param link - The newly created link
   * @param notes - Notes on the link's thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onLinkCreated(link: Link, notes: Note[]): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a link in a connected source channel is updated.
   * Requires `link: true` in Plot options.
   *
   * @param link - The updated link
   * @param notes - Notes on the link's thread (optional)
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onLinkUpdated(link: Link, notes?: Note[]): Promise<void> {
    return Promise.resolve();
  }

  /**
   * Called when a note is created on a thread with a link from a connected channel.
   * Requires `link: true` in Plot options.
   *
   * @param note - The newly created note
   * @param link - The link associated with the thread
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  onLinkNoteCreated(note: Note, link: Link): Promise<void> {
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
