import { ITool, type Tools } from "..";

/**
 * Built-in tool for persistent key-value storage.
 *
 * The Store tool provides agents and tools with a simple, persistent storage
 * mechanism that survives worker restarts and invocations. Each agent/tool
 * instance gets its own isolated storage namespace.
 *
 * **Note:** Store methods are also available directly on Agent and Tool classes
 * via `this.get()`, `this.set()`, `this.clear()`, and `this.clearAll()`.
 * This is the recommended approach for most use cases.
 *
 * **Storage Characteristics:**
 * - Persistent across worker restarts
 * - Isolated per agent/tool instance
 * - Supports any JSON-serializable data
 * - Async operations for scalability
 *
 * **Use Cases:**
 * - Storing authentication tokens
 * - Caching configuration data
 * - Maintaining sync state
 * - Persisting user preferences
 * - Tracking processing checkpoints
 *
 * @example
 * ```typescript
 * class CalendarTool extends Tool {
 *   async saveAuthToken(provider: string, token: string) {
 *     // Using built-in set method (recommended)
 *     await this.set(`auth_token_${provider}`, token);
 *   }
 *
 *   async getAuthToken(provider: string): Promise<string | null> {
 *     // Using built-in get method (recommended)
 *     return await this.get<string>(`auth_token_${provider}`);
 *   }
 *
 *   async clearAllTokens() {
 *     // Using built-in clearAll method (recommended)
 *     await this.clearAll();
 *   }
 * }
 * ```
 */
export class Store extends ITool {
  constructor(_tools: Tools) {
    super();
  }

  /**
   * Retrieves a value from storage by key.
   *
   * Returns the stored value deserialized to the specified type,
   * or null if the key doesn't exist or the value is null.
   *
   * @template T - The expected type of the stored value
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  get<T>(_key: string): Promise<T | null> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Stores a value in persistent storage.
   *
   * The value will be JSON-serialized and stored persistently.
   * Any existing value at the same key will be overwritten.
   *
   * @template T - The type of value being stored
   * @param key - The storage key to use
   * @param value - The value to store (must be JSON-serializable)
   * @returns Promise that resolves when the value is stored
   */
  set<T>(_key: string, _value: T): Promise<void> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Removes a specific key from storage.
   *
   * After this operation, get() calls for this key will return null.
   * No error is thrown if the key doesn't exist.
   *
   * @param key - The storage key to remove
   * @returns Promise that resolves when the key is removed
   */
  clear(_key: string): Promise<void> {
    throw new Error("Method implemented remotely.");
  }

  /**
   * Removes all keys from this storage instance.
   *
   * This operation clears all data stored by this agent/tool instance
   * but does not affect storage for other agents or tools.
   *
   * @returns Promise that resolves when all keys are removed
   */
  clearAll(): Promise<void> {
    throw new Error("Method implemented remotely.");
  }
}
