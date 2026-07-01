/**
 * Types supported by SuperJSON serialization.
 *
 * SuperJSON extends standard JSON serialization to support additional JavaScript types
 * while maintaining type safety and preventing common serialization errors.
 *
 * Supported types:
 * - Primitives: string, number, boolean, null, undefined
 * - Complex types: Date, RegExp, Map, Set, Error, URL, BigInt
 * - Collections: Arrays and objects (recursively)
 *
 * NOT supported (will throw validation errors):
 * - Functions
 * - Symbols
 * - Circular references
 * - Custom class instances (unless explicitly registered)
 */
export type Serializable =
  | string
  | number
  | boolean
  | null
  | undefined
  | Date
  | RegExp
  | Error
  | URL
  | bigint
  | SerializableArray
  | SerializableObject
  | SerializableMap
  | SerializableSet;

/**
 * Array of serializable values.
 *
 * Extends `ReadonlyArray` (not `Array`) so that `readonly` tuples/arrays —
 * e.g. a connector's `reactionCapabilities.allowed` declared with `as const`
 * and reached through `LinkTypeConfig` — still satisfy `Serializable` when the
 * value is stored. A `readonly` array is fully JSON-serializable; the runtime
 * (SuperJSON) never mutates it. Mutable arrays remain assignable, since
 * `Array<T>` extends `ReadonlyArray<T>`.
 */
export interface SerializableArray extends ReadonlyArray<Serializable> {}

/**
 * Object with string keys and serializable values
 */
export interface SerializableObject {
  [key: string]: Serializable;
}

/**
 * Map with serializable keys and values
 */
export interface SerializableMap extends Map<Serializable, Serializable> {}

/**
 * Set with serializable values
 */
export interface SerializableSet extends Set<Serializable> {}
