import { ITool, type Serializable } from "..";

/**
 * Built-in tool for persistent key-value storage.
 *
 * The Store tool provides twists and tools with a simple, persistent storage
 * mechanism that survives worker restarts and invocations. Each twist/tool
 * instance gets its own isolated storage namespace.
 *
 * **Note:** Store methods are also available directly on Twist and Tool classes
 * via `this.get()`, `this.set()`, `this.clear()`, and `this.clearAll()`.
 * This is the recommended approach for most use cases.
 *
 * **Storage Characteristics:**
 * - Persistent across worker restarts
 * - Isolated per twist/tool instance
 * - Supports SuperJSON-serializable data (see below)
 * - Async operations for scalability
 *
 * **Supported Data Types (via SuperJSON):**
 * - Primitives: string, number, boolean, null, undefined
 * - Complex types: Date, RegExp, Map, Set, Error, URL, BigInt
 * - Collections: Arrays and objects (recursively)
 *
 * **NOT Supported (will throw validation errors):**
 * - Functions (use callback tokens instead - see Callbacks tool)
 * - Symbols
 * - Circular references
 * - Custom class instances
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
export abstract class Store extends ITool {
  /**
   * Retrieves a value from storage by key.
   *
   * Returns the stored value deserialized to the specified type,
   * or null if the key doesn't exist or the value is null.
   *
   * Values are automatically deserialized using SuperJSON, which
   * properly restores Date objects, Maps, Sets, and other complex types.
   *
   * @template T - The expected type of the stored value (must be Serializable)
   * @param key - The storage key to retrieve
   * @returns Promise resolving to the stored value or null
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract get<T extends Serializable>(key: string): Promise<T | null>;

  /**
   * Stores a value in persistent storage.
   *
   * The value will be serialized using SuperJSON and stored persistently.
   * Any existing value at the same key will be overwritten.
   *
   * SuperJSON automatically handles Date objects, Maps, Sets, undefined values,
   * and other complex types that standard JSON doesn't support.
   *
   * @template T - The type of value being stored (must be Serializable)
   * @param key - The storage key to use
   * @param value - The value to store (must be SuperJSON-serializable)
   * @returns Promise that resolves when the value is stored
   *
   * @example
   * ```typescript
   * // Date objects are preserved
   * await this.set('sync_state', {
   *   lastSync: new Date(),
   *   minDate: new Date(2024, 0, 1)
   * });
   *
   * // undefined is now supported
   * await this.set('data', { name: 'test', optional: undefined }); // ✅ Works
   *
   * // Arrays with undefined are supported
   * await this.set('items', [1, undefined, 3]); // ✅ Works
   * await this.set('items', [1, null, 3]); // ✅ Also works
   *
   * // Maps and Sets are supported
   * await this.set('mapping', new Map([['key', 'value']])); // ✅ Works
   * await this.set('tags', new Set(['tag1', 'tag2'])); // ✅ Works
   *
   * // Functions are NOT supported - use callback tokens instead
   * const token = await this.callback(this.myFunction);
   * await this.set('callback_ref', token); // ✅ Use callback token
   * ```
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract set<T extends Serializable>(key: string, value: T): Promise<void>;

  /**
   * Removes a specific key from storage.
   *
   * After this operation, get() calls for this key will return null.
   * No error is thrown if the key doesn't exist.
   *
   * @param key - The storage key to remove
   * @returns Promise that resolves when the key is removed
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract clear(key: string): Promise<void>;

  /**
   * Removes all keys from this storage instance.
   *
   * This operation clears all data stored by this twist/tool instance
   * but does not affect storage for other twists or tools.
   *
   * @returns Promise that resolves when all keys are removed
   */
  abstract clearAll(): Promise<void>;
}
