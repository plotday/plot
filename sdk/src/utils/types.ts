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

import type { ITool } from "../agent";
import type { Callbacks } from "../tools/callbacks";
import type { Store } from "../tools/store";
import type { Tasks } from "../tools/tasks";

// ============================================================================
// Type utilities from agent.ts
// ============================================================================

/**
 * Unwraps Promise types to their resolved values.
 * Converts { foo: Promise<string> } to { foo: string }
 */
export type PromiseValues<T> = {
  [K in keyof T]: T[K] extends Promise<infer U> ? U : T[K];
};

/**
 * Extracts the return type from a static Init method.
 */
export type ExtractInitReturn<T> = T extends {
  Init: (...args: any[]) => infer R;
}
  ? R
  : never;

/**
 * Resolves the tools returned by Init, unwrapping any Promises.
 */
export type ResolveInitTools<T> = PromiseValues<ExtractInitReturn<T>>;

/**
 * Built-in tools available to all agents and tools.
 */
export type BuiltInTools<T> = {
  callbacks: Callbacks<T extends new (...args: any[]) => infer I ? I : any>;
  store: Store;
  tasks: Tasks;
} & {}; // Counter reset with intersection

/**
 * Infers the complete set of tools available to an agent or tool,
 * combining tools declared in Init with built-in tools.
 */
export type InferTools<T> = T extends {
  Init: (...args: any[]) => any;
  new (...args: any[]): any;
}
  ? ResolveInitTools<T> & BuiltInTools<T>
  : never;

/**
 * Infers the options type from a static Init method's second parameter.
 */
export type InferOptions<T> = T extends {
  Init: (tools: any, options?: infer O) => any;
}
  ? O
  : undefined;

/**
 * Constraint for types that have both Init static method and constructor.
 */
export type HasInit = {
  Init(tools: ToolBuilder, ...args: any[]): any;
  new (id: string, tools: any, ...args: any[]): any;
};

/**
 * Constructor type for Tool classes (can be abstract or concrete).
 */
export type ToolConstructor<T extends ITool> =
  | (abstract new (id: string, tools: any, options?: any) => T)
  | (new (id: string, tools: any, options?: any) => T);

/**
 * Interface for accessing tool dependencies.
 * Used in static Init methods to initialize tool dependencies.
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

// ============================================================================
// Type utilities from callbacks.ts
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
