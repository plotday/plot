import { type Action, ActionType } from "@plotday/twister/plot";
import type {
  Callback,
  Callbacks as ICallbackTool,
} from "@plotday/twister/tools/callbacks";

import { type Bindings, type TwistEnvironment } from "../../env";
import type { CallbacksState, ResolvedCallback } from "../../state/callbacks";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc, getRpcFunctionName } from "../../utils/rpc";
import { invokeWebhookCallback } from "../invoke-webhook";
import { executeApprovedPlan, storedPlanExists } from "./plot/plan";
import { Tool } from "./tool";

export * from "@plotday/twister/tools/callbacks";

export class Callbacks extends Tool implements ICallbackTool {
  private callbacks: DurableObjectStub<CallbacksState>;
  private twistInstanceId: string;
  private twistId: string;
  private environment: TwistEnvironment;
  private path: string[];

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    twistInstanceId: string
  ) {
    const callbacksId = callbacks.idFromName(twistInstanceId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    callbacks: DurableObjectNamespace<CallbacksState>;
    twistInstanceId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
  }) {
    super();
    this.callbacks = Callbacks.GetStub(
      options.callbacks,
      options.twistInstanceId
    );
    this.twistInstanceId = options.twistInstanceId;
    this.twistId = options.twistId;
    this.environment = options.environment;
    // Remove this tool
    this.path = options.path.slice(0, -1);
  }

  async create(fn: Function, ...extraArgs: any[]): Promise<Callback> {
    const functionName = await getRpcFunctionName(fn);
    disposeRpc(fn);
    if (!functionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    const token = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      functionName,
      extraArgs,
    });
    return token as Callback;
  }

  async createFromParent(fn: Function, ...extraArgs: any[]): Promise<Callback> {
    const functionName = await getRpcFunctionName(fn);
    disposeRpc(fn);
    if (!functionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    const token = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path.slice(0, -1),
      functionName,
      extraArgs,
    });
    return token as Callback;
  }

  /**
   * Resolves callback metadata without executing it.
   *
   * This is the fast path used by the twist worker's MODULE code to avoid
   * the expensive full-reconstruction path in callCallback(). Instead of
   * constructing a new twist (Supabase queries, module loading, permission
   * checks, tool tree rebuild), the twist worker calls resolve() to get
   * the callback metadata, then executes the function directly on its
   * already-constructed tool tree.
   *
   * The interception happens in entrypoint.ts MODULE: ToolShed.waitForReady()
   * wraps callbacks.run() to call resolve() + local execution instead.
   *
   * @see {@link CallbacksState.resolve} for the DO implementation
   * @see entrypoint.ts MODULE ToolShed.waitForReady() for the interception
   */
  async resolve(callback: Callback): Promise<ResolvedCallback | null> {
    const result = await this.callbacks.resolve(callback);
    if (!result) return result;
    const resolved = {
      ...result,
      path: [...result.path],
      extraArgs: result.extraArgs ? [...result.extraArgs] : undefined,
    };
    return resolved;
  }

  /**
   * Executes a callback by its token.
   *
   * NOTE: When called from within a twist worker, this method is intercepted
   * by the MODULE code in entrypoint.ts. The interceptor calls resolve()
   * instead, then executes the callback locally on the already-constructed
   * tool tree — avoiding the full twist reconstruction that callCallback()
   * performs. This method only runs as a fallback if local resolution fails.
   *
   * @see entrypoint.ts MODULE ToolShed.waitForReady() for the interception
   */
  async run(callback: Callback, ...args: any[]): Promise<any> {
    const result = await this.callbacks.callCallback(callback, ...(args ?? []));
    return result;
  }

  async delete(callback: Callback): Promise<void> {
    await this.callbacks.delete(callback);
  }

  async deleteAll(): Promise<void> {
    await this.callbacks.deleteAll({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
    });
  }

  /**
   * Static method to handle activity link callbacks from API endpoints.
   *
   * Executes the callback via `invokeWebhookCallback` so the twist worker
   * RPC runs in the calling worker's context, not inside the
   * CallbacksState DO. This keeps the DO's output gate free during long
   * callbacks and matches how the webhook queue consumer dispatches.
   */
  static async HandleActionCallback(
    env: Bindings,
    ctx: { exports: ExecutionContext["exports"] },
    token: string,
    action: Action,
    // The authenticated user id from the approval request's app-auth session.
    // Optional so non-plan / non-route callers are unaffected; the plan branch
    // requires it to enforce owner-only execution.
    authenticatedUserId?: string | null
  ): Promise<any> {
    try {
      if (
        action.type !== ActionType.callback &&
        action.type !== ActionType.plan
      ) {
        throw new Error("Action is not a callback or plan type");
      }

      const callbackToken = action.callback;
      if (!callbackToken) {
        throw new Error("No callback token found in thread action");
      }

      if (callbackToken !== token) {
        throw new Error("Callback token mismatch");
      }

      if (action.type === ActionType.plan) {
        const approved = action.approved === true;
        if (approved) {
          // Execute the SERVER-STORED plan (owner-only, capped). The
          // operations the client POSTed are ignored for execution; we
          // overwrite BOTH action.operations and action.results with the
          // authoritative stored set so the twist's onPlanResponse zips
          // operations↔results by the same index. If executeApprovedPlan
          // throws (NOT_FOUND / owner mismatch / expired token), nothing
          // executes and — because the token delete only happens in the
          // dispatch finally below — the token survives for a legitimate
          // later approval.
          const { results, operations } = await executeApprovedPlan(
            env,
            token,
            authenticatedUserId
          );
          action.operations = operations;
          action.results = results;
          try {
            return await invokeWebhookCallback(env, ctx, callbackToken, action, true);
          } finally {
            // Replay guard: once an approved plan's operations have executed,
            // the plan is consumed — delete the token even when the callback
            // dispatch throws, so a re-approval can never re-run the
            // (non-idempotent) operations. The delete cannot happen BEFORE
            // the dispatch: invokeWebhookCallback resolves the callback by
            // this same token (CallbacksState.validateAndLoad), so deleting
            // first would fail the dispatch itself with NOT_FOUND and the
            // twist would never receive (action, approved). A dispatch
            // failure therefore only costs the confirmation note (surfaced
            // via the route's captureServerError), never data correctness.
            const [doIdHex] = callbackToken.split(":");
            const stub = env.CALLBACKS.get(env.CALLBACKS.idFromString(doIdHex));
            try {
              await stub.delete(callbackToken);
            } catch {
              // best-effort cleanup
            } finally {
              disposeRpc(stub);
            }
          }
        } else if (await storedPlanExists(env, token)) {
          // Rejected plans: nothing executes and the token stays live so
          // the user can still approve later. Plan-ness is VERIFIED against
          // the server-stored plan first — a mislabeled `type: "plan"`
          // payload POSTed against a non-plan token must NOT get the extra
          // positional `approved` arg (which would shift an arbitrary
          // callback's curried extraArgs); it falls through to the legacy
          // single-arg dispatch below instead, behaving exactly as before
          // plans existed. The approved arm needs no such check:
          // executeApprovedPlan itself fails closed with NOT_FOUND when no
          // stored plan backs the token.
          return await invokeWebhookCallback(env, ctx, callbackToken, action, false);
        }
        // Not a real plan decision — fall through to the legacy dispatch.
      }

      return await invokeWebhookCallback(env, ctx, callbackToken, action);
    } catch (error) {
      const logger = createLogger();
      logger.error("Error handling action callback", error as Error, {
        callback_token: token,
      });
      throw error;
    }
  }

  /** @deprecated Use HandleActionCallback */
  static HandleLinkCallback = Callbacks.HandleActionCallback;
}
