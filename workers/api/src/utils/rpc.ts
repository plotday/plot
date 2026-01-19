/**
 * Utility types for handling Cloudflare Workers RPC transformations.
 *
 * When crossing RPC boundaries, Cloudflare Workers transforms function parameters
 * into Rpc.Stub objects. These utilities help maintain type safety while keeping
 * public SDK types clean.
 *
 * Note: Rpc is a global namespace from Cloudflare Workers type definitions.
 */

/**
 * Transforms a function type to its RPC stub equivalent.
 *
 * When a function is passed across an RPC boundary, it becomes a stub where
 * properties (like `name`) require `await` to access.
 *
 * @example
 * ```typescript
 * type MyFunc = (x: number) => string;
 * type RpcMyFunc = RpcFunction<MyFunc>; // Rpc.Stub<MyFunc>
 * ```
 */
export type RpcFunction<F extends (...args: any[]) => any> = Rpc.Stub<F>;

/**
 * Transforms method parameters, converting functions to RPC stubs.
 *
 * This preserves the parameter structure while transforming any function
 * parameters into their RPC stub equivalents.
 *
 * @example
 * ```typescript
 * type Params = [string, (x: number) => void, boolean];
 * type RpcParams = RpcTransformParams<Params>;
 * // [string, Rpc.Stub<(x: number) => void>, boolean]
 * ```
 */
export type RpcTransformParams<P extends any[]> = {
  [K in keyof P]: P[K] extends (...args: any[]) => any
    ? RpcFunction<P[K]>
    : P[K];
};

/**
 * Transforms a method signature for RPC implementation.
 *
 * Converts function parameters to RPC stubs while preserving other types.
 *
 * @example
 * ```typescript
 * type Method = (name: string, callback: (x: number) => void) => Promise<void>;
 * type RpcMethod = RpcMethod<Method>;
 * // (name: string, callback: Rpc.Stub<(x: number) => void>) => Promise<void>
 * ```
 */
export type RpcMethod<M> = M extends (...args: infer P) => infer R
  ? (...args: RpcTransformParams<P>) => R
  : M;

/**
 * Transforms an entire interface to its RPC implementation version.
 *
 * Recursively transforms all methods in an interface, converting function
 * parameters to RPC stubs. This is useful for typing built-in tool implementations
 * that receive RPC-transformed parameters from twists.
 *
 * @example
 * ```typescript
 * interface MyTool {
 *   doSomething(callback: (x: number) => void): Promise<void>;
 *   getValue(): string;
 * }
 *
 * type MyToolRpc = RpcImplementation<MyTool>;
 * // {
 * //   doSomething(callback: Rpc.Stub<(x: number) => void>): Promise<void>;
 * //   getValue(): string;
 * // }
 * ```
 */
export type RpcImplementation<T> = {
  [K in keyof T]: RpcMethod<T[K]>;
};

/**
 * Helper to access the 'name' property of an RPC stub function.
 *
 * When a function crosses an RPC boundary, accessing properties like `name`
 * requires an await. This helper provides a convenient way to get the function name.
 *
 * @example
 * ```typescript
 * async function processCallback<F extends (...args: any[]) => any>(
 *   callback: RpcFunction<F>
 * ) {
 *   const name = await getRpcFunctionName(callback);
 *   console.log(`Callback name: ${name}`);
 * }
 * ```
 */
export async function getRpcFunctionName(
  stub: RpcFunction<any> | Function
): Promise<string> {
  // RPC stubs require await to access properties
  // The type system doesn't expose this cleanly, so we use 'as any'
  const name = await (stub as any).name;
  return name || "";
}

/**
 * Type guard to check if a value is an RPC stub.
 *
 * Note: This is a runtime check and may not be 100% reliable, as RPC stubs
 * are functions. Use with caution.
 */
export function isRpcStub(value: unknown): value is Rpc.Stub<any> {
  return (
    typeof value === "function" && typeof (value as any).dup === "function"
  );
}

/**
 * Safely dispose an RPC result or stub using Symbol.dispose.
 * Call this after you're done with any RPC method call result.
 *
 * Per Cloudflare docs: "Store returned objects in `using` declarations
 * even without expected stubs (future-proofs against API changes)"
 *
 * @see https://developers.cloudflare.com/workers/runtime-apis/rpc/lifecycle/
 */
export function disposeRpc(value: unknown): void {
  if (value != null && typeof value === "object" && Symbol.dispose in value) {
    try {
      (value as { [Symbol.dispose]: () => void })[Symbol.dispose]();
    } catch {
      // Ignore disposal errors - stub may already be disposed
    }
  }
}
