import type { CallbacksState } from "../state/callbacks";
import { disposeRpc, getRpcFunctionName } from "../utils/rpc";

/**
 * Invokes a callback method on a twist or tool via the rebuild-and-bind
 * dispatch path — the ONLY safe way to call a twist/connector method that was
 * passed across the Cloudflare Workers RPC boundary.
 *
 * See `CALLBACKS.md` in this directory for the rationale. In short: a method
 * reference like `this.syncBatch` arrives in a built-in tool as an
 * `Rpc.Stub<Function>`. Calling the stub directly executes only that method
 * body — sibling private methods and `this.*` state on the enclosing class
 * are unreachable. The symptom is `TypeError: this.X is not a function`.
 *
 * This helper dispatches the call through `CallbacksState.callCallback`, which
 * runs inside the twist worker, rebuilds the twist instance, and invokes the
 * named method with `method.call(twist, ...)`. The method sees the full class
 * with all its private methods and state.
 *
 * Runtime args come first in the resulting call, extraArgs last — matching
 * the shape used everywhere else in the callback system (e.g. the slow path
 * in `Integrations.actAs` and `Tasks.runTask`).
 *
 * @param callbacks      CallbacksState DO stub for the twist instance.
 * @param twistInstanceId The owning `twist_instance.id`.
 * @param callback       Method reference (Rpc.Stub) received across RPC.
 * @param path           Tool path where the method lives. Use `[]` for a
 *                       twist-level method, the parent tool's path for a
 *                       connector method (e.g. `integrations.path.slice(0, -1)`).
 * @param extraArgs      Args bound at registration time, appended after
 *                       `args` when the method is invoked.
 * @param args           Args passed in first when the method runs.
 * @returns The method's return value (already unwrapped from the DO response).
 */
export async function invokeCallback(
  callbacks: DurableObjectStub<CallbacksState>,
  twistInstanceId: string,
  callback: (...args: any[]) => any,
  path: string[],
  extraArgs: any[],
  ...args: any[]
): Promise<any> {
  // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
  const functionName = await getRpcFunctionName(callback);
  disposeRpc(callback);
  if (!functionName) {
    throw new Error(
      "Cannot invoke callback: function has no name. Use named functions or methods."
    );
  }

  const token = await callbacks.create({
    twistInstanceId,
    path,
    functionName,
    extraArgs,
    callOnce: true,
  });

  return await callbacks.callCallback(token, ...args);
}
