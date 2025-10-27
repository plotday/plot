/**
 * Internal type utilities for SDK implementation.
 *
 * This file contains advanced TypeScript type utilities used internally
 * by the SDK to provide type-safe APIs. Most developers don't need to
 * reference these types directly - they work behind the scenes to power
 * the Agent and Tool APIs.
 *
 * @internal
 */
import type { Callbacks } from "../tools/callbacks";
import type { Store } from "../tools/store";
import type { Tasks } from "../tools/tasks";

// ============================================================================
// Type utilities for agent.ts
// ============================================================================

/**
 * Unwraps Promise types to their resolved values.
 * Converts { foo: Promise<string> } to { foo: string }
 */
export type PromiseValues<T> = {
  [K in keyof T]: T[K] extends Promise<infer U> ? U : T[K];
};

/**
 * Extracts the return type from an instance build method.
 */
export type ExtractBuildReturn<T> = T extends {
  build: (...args: any[]) => infer R;
}
  ? R
  : {};

/**
 * Built-in tools available to all agents and tools.
 */
export type BuiltInTools = {
  callbacks: Callbacks;
  store: Store;
  tasks: Tasks;
};

/**
 * Infers the complete set of tools available to an agent or tool,
 * combining tools declared in build with built-in tools.
 */
export type InferTools<T> = PromiseValues<ExtractBuildReturn<T>> & BuiltInTools;

/**
 * Infers the options type from a constructor's second parameter.
 */
export type InferOptions<T> = T extends {
  Options: infer O;
}
  ? O
  : unknown;

/**
 * Function type for building tool dependencies.
 * Used in build methods to request tool instances.
 */
export type ToolBuilder = <TC extends abstract new (...args: any) => any>(
  ToolClass: TC,
  options?: InferOptions<TC>
) => Promise<InstanceType<TC>>;

/**
 * Interface for managing tool initialization and lifecycle.
 * Implemented by the agent runtime to provide tools to agents and tools.
 */
export interface ToolShed {
  /**
   * Build function for requesting tool dependencies
   */
  build: ToolBuilder;

  /**
   * Whether tools are ready (all promises resolved)
   */
  readonly ready: boolean;

  /**
   * Wait for all tool promises to resolve
   */
  waitForReady(): Promise<void>;

  /**
   * Get resolved tools (throws if not ready)
   */
  getTools<T>(): T;
}

// ============================================================================
// Type utilities for callbacks.ts
// ============================================================================

/**
 * Represents any non-function type.
 */
export type NonFunction = Exclude<unknown, (...args: any[]) => any>;

/**
 * Filters out function properties from a type, keeping only data properties.
 * For arrays, keeps the array structure while filtering functions from elements.
 */
export type NoFunctions<T> = T extends (...args: any[]) => any
  ? never
  : T extends object
  ? { [K in keyof T]: T[K] extends (...args: any[]) => any ? never : T[K] }
  : T;

/**
 * Extracts method names from a type that are functions.
 * Used to type-check callback method references.
 */
export type CallbackMethods<T> = {
  [K in keyof T]: T[K] extends (...args: any[]) => any ? K : never;
}[keyof T];
