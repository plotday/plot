import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// Regression test: team subscription with legacy plan='core' must not crash
// getSyncHistoryMin(). Pre-fix: teamSub.plan cast as PlanKey → 'core' flowed
// into PLAN_LIMITS['core'] (undefined) → TypeError. Post-fix: core→free coercion
// at the read boundary returns the FREE cutoff (7 days) without throwing.

const TWIST_INSTANCE_ID = "test-twist-instance-id";
const OWNER_ID = "test-owner-id";
const TEAM_ID = "test-team-id";

/**
 * Table-aware Kysely stub for getSyncHistoryMin:
 *  - selectFrom("twist_instance") → { owner_id, team_id }
 *  - selectFrom("team_subscription") → { plan, status }
 */
function mockDbForSyncHistory(opts: {
  teamSubPlan: string;
  teamSubStatus: string;
}) {
  function chain(table?: string): any {
    return {
      selectFrom: (t: string) => chain(t),
      select: () => chain(table),
      where: () => chain(table),
      executeTakeFirst: async () => {
        if (table === "twist_instance") {
          return { owner_id: OWNER_ID, team_id: TEAM_ID };
        }
        if (table === "team_subscription") {
          return { plan: opts.teamSubPlan, status: opts.teamSubStatus };
        }
        return undefined;
      },
    };
  }
  return chain();
}

function makeIntegrationsThis(opts: { teamSubPlan: string; teamSubStatus: string }) {
  return {
    twistInstanceId: TWIST_INSTANCE_ID,
    db: mockDbForSyncHistory(opts),
    // Start with cache unset so getSyncHistoryMin performs the full DB path.
    _syncHistoryMin: undefined,
    // Bind the prototype method so `this.x` resolves on the plain object.
    getSyncHistoryMin: Integrations.prototype.getSyncHistoryMin,
  } as any;
}

describe("getSyncHistoryMin — core→free coercion at read boundary", () => {
  it("REGRESSION: team sub with plan='core' returns the FREE 7-day cutoff without throwing", async () => {
    const self = makeIntegrationsThis({ teamSubPlan: "core", teamSubStatus: "active" });

    const result = await self.getSyncHistoryMin();

    // Must not throw. Must return a Date (not null — owner_id is set).
    expect(result).toBeInstanceOf(Date);

    // The FREE limit is 7 days. The result should be approximately 7 days ago.
    // Allow a 1-minute window to guard against test clock jitter.
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    const diffMs = Math.abs(result!.getTime() - sevenDaysAgo.getTime());
    expect(diffMs).toBeLessThan(60_000); // within 1 minute
  });

  it("team sub with plan='team' (active) returns the PRO/TEAM 365-day cutoff", async () => {
    const self = makeIntegrationsThis({ teamSubPlan: "team", teamSubStatus: "active" });

    const result = await self.getSyncHistoryMin();

    expect(result).toBeInstanceOf(Date);
    const threeSixtyFiveDaysAgo = new Date();
    threeSixtyFiveDaysAgo.setDate(threeSixtyFiveDaysAgo.getDate() - 365);
    const diffMs = Math.abs(result!.getTime() - threeSixtyFiveDaysAgo.getTime());
    expect(diffMs).toBeLessThan(60_000);
  });

  it("team sub with plan='core' but status='canceled' falls back to FREE 7-day cutoff", async () => {
    const self = makeIntegrationsThis({ teamSubPlan: "core", teamSubStatus: "canceled" });

    const result = await self.getSyncHistoryMin();

    expect(result).toBeInstanceOf(Date);
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    const diffMs = Math.abs(result!.getTime() - sevenDaysAgo.getTime());
    expect(diffMs).toBeLessThan(60_000);
  });
});
