/**
 * Tests for the plan branch of Callbacks.HandleActionCallback.
 *
 * Contract (Task 2, hardened by the final whole-branch review):
 * - approved === true → executeApprovedPlan resolves and EXECUTES the
 *   SERVER-STORED plan (owner-only, capped). The client-supplied
 *   `action.operations` are IGNORED for execution and OVERWRITTEN with the
 *   authoritative operations executeApprovedPlan returns, alongside
 *   `action.results` (so the twist's onPlanResponse zips operations↔results
 *   by the same index). executeApprovedPlan is passed the authenticated user
 *   id so it can enforce owner-only execution. The twist callback is
 *   dispatched as (action, true) and the token is deleted (replay guard) EVEN
 *   IF the dispatch throws.
 * - approved falsy → no execution, no token delete (user may approve later),
 *   dispatch as (action, false) — but ONLY when a server-stored plan actually
 *   backs the token (storedPlanExists). A mislabeled `type: "plan"` payload
 *   against a non-plan token falls through to the LEGACY single-arg dispatch,
 *   so the extra positional `false` can never argument-shift an arbitrary
 *   callback's curried extraArgs.
 * - executeApprovedPlan throwing (NOT_FOUND / owner mismatch / expired) →
 *   nothing dispatches and the token is NOT deleted (deletion only happens in
 *   the dispatch finally, which is never reached).
 * - non-plan actions keep the legacy single-action dispatch.
 *
 * NOTE on ordering: the token delete happens AFTER the dispatch attempt (in a
 * finally), not before it — invokeWebhookCallback resolves the callback by
 * this same token via CallbacksState.validateAndLoad, so deleting first would
 * fail the dispatch itself with NOT_FOUND.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type Action, ActionType } from "@plotday/twister/plot";

import { invokeWebhookCallback } from "../invoke-webhook";
import { Callbacks } from "./callbacks";
import { executeApprovedPlan, storedPlanExists } from "./plot/plan";

// vi.mock calls are hoisted above the imports by vitest.
vi.mock("../invoke-webhook", () => ({
  invokeWebhookCallback: vi.fn(),
}));
vi.mock("./plot/plan", () => ({
  executeApprovedPlan: vi.fn(),
  storedPlanExists: vi.fn(),
}));

const invokeMock = vi.mocked(invokeWebhookCallback);
const executeMock = vi.mocked(executeApprovedPlan);
const planExistsMock = vi.mocked(storedPlanExists);

const DO_ID_HEX = "a".repeat(64);
const TOKEN = `${DO_ID_HEX}:cb-token`;
const AUTH_USER_ID = "user-owner";

// The authoritative operations executeApprovedPlan resolves from the stored
// plan note. Deliberately different from the client-supplied ones below so we
// can prove the stored set wins.
const STORED_OPS = [
  { type: "createNote", threadId: "t-stored", threadTitle: "S", content: "stored" },
] as any;

function makeHarness() {
  const deleteFn = vi.fn().mockResolvedValue(undefined);
  const stub = { delete: deleteFn };
  const env = {
    CALLBACKS: {
      idFromString: vi.fn().mockReturnValue("do-id"),
      get: vi.fn().mockReturnValue(stub),
    },
  } as any;
  const ctx = { exports: {} } as any;
  return { env, ctx, deleteFn };
}

function planAction(overrides: Record<string, unknown> = {}): Action {
  return {
    type: ActionType.plan,
    title: "Tidy up",
    // Client-supplied operations — these must NOT be executed; the stored
    // plan's operations are authoritative.
    operations: [
      { type: "createNote", threadId: "t-client", threadTitle: "C", content: "tampered" },
    ],
    callback: TOKEN,
    ...overrides,
  } as unknown as Action;
}

beforeEach(() => {
  vi.clearAllMocks();
  invokeMock.mockResolvedValue("dispatched");
  executeMock.mockResolvedValue({ results: [{ success: true }], operations: STORED_OPS });
  // Default: a genuine server-stored plan backs the token.
  planExistsMock.mockResolvedValue(true);
});

describe("HandleActionCallback plan branch", () => {
  it("approved: executes the stored plan, overwrites operations+results, dispatches (action, true), deletes token", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction({ approved: true });

    const result = await Callbacks.HandleActionCallback(
      env,
      ctx,
      TOKEN,
      action,
      AUTH_USER_ID
    );

    expect(result).toBe("dispatched");
    expect(executeMock).toHaveBeenCalledTimes(1);
    // Owner-only: the authenticated user id is plumbed through; the client
    // operations are NOT passed (server reads them from the stored note).
    expect(executeMock).toHaveBeenCalledWith(env, TOKEN, AUTH_USER_ID);
    // Both results AND operations are overwritten with the authoritative set.
    expect((action as any).results).toEqual([{ success: true }]);
    expect((action as any).operations).toBe(STORED_OPS);
    expect(invokeMock).toHaveBeenCalledTimes(1);
    expect(invokeMock).toHaveBeenCalledWith(env, ctx, TOKEN, action, true);
    expect(deleteFn).toHaveBeenCalledTimes(1);
    expect(deleteFn).toHaveBeenCalledWith(TOKEN);
    // Execution strictly precedes dispatch (results ride on the action).
    expect(executeMock.mock.invocationCallOrder[0]).toBeLessThan(
      invokeMock.mock.invocationCallOrder[0]
    );
  });

  it("stored operations win over client-supplied operations", async () => {
    const { env, ctx } = makeHarness();
    const action = planAction({ approved: true });
    const clientOps = (action as any).operations;

    await Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID);

    // The tampered client operations are discarded entirely.
    expect((action as any).operations).not.toBe(clientOps);
    expect((action as any).operations).toBe(STORED_OPS);
    // executeApprovedPlan is never handed the client operations.
    expect(executeMock).toHaveBeenCalledWith(env, TOKEN, AUTH_USER_ID);
    expect(executeMock.mock.calls[0]).not.toContain(clientOps);
  });

  it("approved but no stored plan (executeApprovedPlan throws NOT_FOUND): no dispatch, no delete", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction({ approved: true });
    executeMock.mockRejectedValueOnce(new Error("Callback not found"));

    await expect(
      Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID)
    ).rejects.toThrow("Callback not found");

    // Nothing executed downstream, and the token survives for a later approval.
    expect(invokeMock).not.toHaveBeenCalled();
    expect(deleteFn).not.toHaveBeenCalled();
  });

  it("approved: deletes the token even when the callback dispatch throws (no duplicate-execution window)", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction({ approved: true });
    invokeMock.mockRejectedValueOnce(new Error("twist suspended"));

    await expect(
      Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID)
    ).rejects.toThrow("twist suspended");

    // Operations executed, so the plan is consumed regardless of dispatch
    // outcome — a re-approval must never re-run them.
    expect(executeMock).toHaveBeenCalledTimes(1);
    expect(deleteFn).toHaveBeenCalledTimes(1);
    expect(deleteFn).toHaveBeenCalledWith(TOKEN);
  });

  it("rejected (approved: false) on a genuine plan token: no execution, no delete, dispatches (action, false)", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction({ approved: false });

    await Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID);

    // Plan-ness was verified against the server-stored plan.
    expect(planExistsMock).toHaveBeenCalledWith(env, TOKEN);
    expect(executeMock).not.toHaveBeenCalled();
    expect(deleteFn).not.toHaveBeenCalled();
    expect((action as any).results).toBeUndefined();
    expect(invokeMock).toHaveBeenCalledWith(env, ctx, TOKEN, action, false);
  });

  it("approved absent: treated as not approved", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction();

    await Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID);

    expect(executeMock).not.toHaveBeenCalled();
    expect(deleteFn).not.toHaveBeenCalled();
    expect(invokeMock).toHaveBeenCalledWith(env, ctx, TOKEN, action, false);
  });

  it('mislabeled `type: "plan"` with approved false and NO stored plan: legacy 4-arg dispatch (no injected `false`)', async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = planAction({ approved: false });
    planExistsMock.mockResolvedValueOnce(false);

    const result = await Callbacks.HandleActionCallback(
      env,
      ctx,
      TOKEN,
      action,
      AUTH_USER_ID
    );

    expect(result).toBe("dispatched");
    expect(planExistsMock).toHaveBeenCalledWith(env, TOKEN);
    expect(executeMock).not.toHaveBeenCalled();
    expect(deleteFn).not.toHaveBeenCalled();
    expect(invokeMock).toHaveBeenCalledTimes(1);
    // Exactly the legacy four args — the extra positional `false` must NOT
    // be injected between `action` and the callback's curried extraArgs.
    expect(invokeMock.mock.calls[0]).toHaveLength(4);
    expect(invokeMock.mock.calls[0]).toEqual([env, ctx, TOKEN, action]);
  });

  it("approved arm does not consult storedPlanExists (executeApprovedPlan fails closed itself)", async () => {
    const { env, ctx } = makeHarness();
    const action = planAction({ approved: true });

    await Callbacks.HandleActionCallback(env, ctx, TOKEN, action, AUTH_USER_ID);

    expect(planExistsMock).not.toHaveBeenCalled();
    expect(executeMock).toHaveBeenCalledTimes(1);
  });

  it("non-plan (callback) action: legacy single-action dispatch, untouched", async () => {
    const { env, ctx, deleteFn } = makeHarness();
    const action = {
      type: ActionType.callback,
      title: "Do it",
      callback: TOKEN,
    } as unknown as Action;

    const result = await Callbacks.HandleActionCallback(
      env,
      ctx,
      TOKEN,
      action,
      AUTH_USER_ID
    );

    expect(result).toBe("dispatched");
    expect(executeMock).not.toHaveBeenCalled();
    expect(deleteFn).not.toHaveBeenCalled();
    expect(invokeMock).toHaveBeenCalledTimes(1);
    // Exactly the legacy four args — no trailing `approved`, no user id leak.
    expect(invokeMock.mock.calls[0]).toHaveLength(4);
    expect(invokeMock.mock.calls[0]).toEqual([env, ctx, TOKEN, action]);
  });
});
