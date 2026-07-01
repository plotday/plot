import { describe, it, expect, vi } from "vitest";
import { reconcileAddonsAtPeriodEnd } from "./addon-period-reconcile";
import * as ti from "../app/twist-integrations";

function mockDb(userSubs: any[], teamSubs: any[]) {
  return {
    selectFrom: (t: string) => ({
      select: () => ({
        where: () => ({
          limit: () => ({
            execute: async () => (t === "user_subscription" ? userSubs : teamSubs),
          }),
        }),
      }),
    }),
  } as any;
}

describe("reconcileAddonsAtPeriodEnd", () => {
  it("reconciles only subs whose period ends within the window", async () => {
    const now = 1_000_000_000_000;
    const spy = vi
      .spyOn(ti, "reconcileScopeAddonBillingDown")
      .mockResolvedValue(undefined);
    const db = mockDb(
      [
        { user_id: "u_soon", stripe_addon_subscription_id: "sub_soon" },
        { user_id: "u_later", stripe_addon_subscription_id: "sub_later" },
      ],
      []
    );
    const stripe = {
      subscriptions: {
        retrieve: vi.fn(async (id: string) => ({
          current_period_end:
            id === "sub_soon"
              ? Math.floor((now + 60 * 60 * 1000) / 1000) // +1h
              : Math.floor((now + 5 * 24 * 60 * 60 * 1000) / 1000), // +5d
        })),
      },
    } as any;

    const res = await reconcileAddonsAtPeriodEnd({
      db, stripe, nowMs: now, windowMs: 24 * 60 * 60 * 1000,
    });

    expect(res.reconciled).toBe(1);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({ scope: { userId: "u_soon" } })
    );
  });

  it("reconciles an in-window team_subscription target with a team scope", async () => {
    const now = 1_000_000_000_000;
    const spy = vi
      .spyOn(ti, "reconcileScopeAddonBillingDown")
      .mockResolvedValue(undefined);
    const db = mockDb(
      [],
      [{ team_id: "team_soon", stripe_addon_subscription_id: "sub_team_soon" }]
    );
    const stripe = {
      subscriptions: {
        retrieve: vi.fn(async () => ({
          current_period_end: Math.floor((now + 60 * 60 * 1000) / 1000), // +1h
        })),
      },
    } as any;

    const res = await reconcileAddonsAtPeriodEnd({
      db, stripe, nowMs: now, windowMs: 24 * 60 * 60 * 1000,
    });

    expect(res.reconciled).toBe(1);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({ scope: { teamId: "team_soon" } })
    );
  });

  it("isolates a failing target so later targets are still reconciled", async () => {
    const now = 1_000_000_000_000;
    const spy = vi
      .spyOn(ti, "reconcileScopeAddonBillingDown")
      .mockResolvedValue(undefined);
    const db = mockDb(
      [
        { user_id: "u_fail", stripe_addon_subscription_id: "sub_fail" },
        { user_id: "u_ok", stripe_addon_subscription_id: "sub_ok" },
      ],
      []
    );
    const stripe = {
      subscriptions: {
        retrieve: vi.fn(async (id: string) => {
          if (id === "sub_fail") throw new Error("Stripe error: no such subscription");
          return {
            current_period_end: Math.floor((now + 60 * 60 * 1000) / 1000), // +1h
          };
        }),
      },
    } as any;

    const res = await reconcileAddonsAtPeriodEnd({
      db, stripe, nowMs: now, windowMs: 24 * 60 * 60 * 1000,
    });

    expect(res.reconciled).toBe(1);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({ scope: { userId: "u_ok" } })
    );
  });

  it("warns when a scan hits the per-run cap so truncation is never silent", async () => {
    const now = 1_000_000_000_000;
    vi.spyOn(ti, "reconcileScopeAddonBillingDown").mockResolvedValue(undefined);
    const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});

    // 250 user_subscription rows == RECONCILE_SCAN_LIMIT, simulating the query
    // having hit its .limit(250) cap; team_subscription stays well under.
    const userSubs = Array.from({ length: 250 }, (_, i) => ({
      user_id: `u_${i}`,
      stripe_addon_subscription_id: `sub_${i}`,
    }));
    const db = mockDb(userSubs, [
      { team_id: "team_a", stripe_addon_subscription_id: "sub_team_a" },
    ]);
    const stripe = {
      subscriptions: {
        // Put every target outside the window so reconcile logic itself is a no-op;
        // this test only cares about the cap-hit warning.
        retrieve: vi.fn(async () => ({
          current_period_end: Math.floor((now + 30 * 24 * 60 * 60 * 1000) / 1000), // +30d
        })),
      },
    } as any;

    await reconcileAddonsAtPeriodEnd({
      db, stripe, nowMs: now, windowMs: 24 * 60 * 60 * 1000,
    });

    const warnedMessages = consoleWarn.mock.calls.map((c) => JSON.stringify(c));
    expect(warnedMessages.some((m) => m.includes("user_subscription") && m.includes("RECONCILE_SCAN_LIMIT"))).toBe(true);
    expect(warnedMessages.some((m) => m.includes("team_subscription") && m.includes("RECONCILE_SCAN_LIMIT"))).toBe(false);

    consoleWarn.mockRestore();
  });
});
