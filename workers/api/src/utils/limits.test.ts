import { randomUUID } from "node:crypto";

import { Kysely, PostgresDialect, sql } from "kysely";
import pg from "pg";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  checkChannelConnectionLimit,
  checkTwistCapacity,
  computeTwistBlocksNeeded,
  getBillableConnectionAddonCount,
  getPersonalConnectionCount,
  getPersonalTwistWeightSum,
  getTeamConnectionCount,
  getUsage,
  PLAN_LIMITS,
  selectConnectionsToTrim,
  type PlanKey,
  type TrimmableConnection,
} from "./limits";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Seed one source twist + twist_instance + a single channel (enabled or not),
 * then return what the connection-count function reports for that scope. The
 * whole thing runs in a transaction that is rolled back, so the DB is left
 * untouched. FK/identity triggers are disabled via `session_replication_role`
 * during seeding (mirrors recover-stuck-syncs.test.ts).
 */
async function seedAndCount(opts: {
  scope: "personal" | "team";
  channelEnabled: boolean;
  premium?: boolean;
}): Promise<number> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const teamId = 987654;
  const twistInstanceId = randomUUID();

  let count = 0;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      // A personal-environment source twist satisfies the twist CHECK
      // constraint (user_id set, publisher_id null). The count queries inspect
      // is_source = true; premium is parameterized by opts.premium.
      const twist = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, environment, user_id, name, handle, version,
           is_source, premium)
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, ${opts.premium ?? false})
        RETURNING id`.execute(trx);
      const twistId = twist.rows[0].id;

      await sql`INSERT INTO twist_instance
          (id, twist_id, owner_id, name, team_id)
        VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid,
          'LinkedIn', ${opts.scope === "team" ? teamId : null})`.execute(trx);

      // channel.id is GENERATED ALWAYS AS IDENTITY — omit it.
      await sql`INSERT INTO channel
          (twist_instance_id, channel_id, title, enabled)
        VALUES (${twistInstanceId}::uuid, 'linkedin', 'LinkedIn',
          ${opts.channelEnabled})`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      count =
        opts.scope === "personal"
          ? await getPersonalConnectionCount(trx, userId)
          : await getTeamConnectionCount(trx, String(teamId));

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return count;
}

// A "stuck" connection — needs_reauth set but every channel disabled — must not
// consume a connection slot. The count is gated on EXISTS(enabled channel), so
// disabling the last channel drops it out of the quota for both scopes.
describe.skipIf(!DATABASE_URL)("connection quota excludes stuck instances", () => {
  it("personal: an instance with an enabled channel counts", async () => {
    expect(await seedAndCount({ scope: "personal", channelEnabled: true })).toBe(
      1
    );
  });

  it("personal: an instance with no enabled channel does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "personal", channelEnabled: false })
    ).toBe(0);
  });

  it("team: an instance with an enabled channel counts", async () => {
    expect(await seedAndCount({ scope: "team", channelEnabled: true })).toBe(1);
  });

  it("team: an instance with no enabled channel does NOT count", async () => {
    expect(await seedAndCount({ scope: "team", channelEnabled: false })).toBe(0);
  });

  it("personal: an enabled ADD-ON (premium) instance does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "personal", channelEnabled: true, premium: true })
    ).toBe(0);
  });

  it("team: an enabled ADD-ON (premium) instance does NOT count", async () => {
    expect(
      await seedAndCount({ scope: "team", channelEnabled: true, premium: true })
    ).toBe(0);
  });
});

describe("selectConnectionsToTrim", () => {
  let seq = 0;
  /** Build a connection. `connectedAt` increments per call so later calls are
   * "newer" — pass an explicit value to control ordering. */
  const conn = (
    overrides: Partial<TrimmableConnection> & { premium: boolean }
  ): TrimmableConnection => ({
    twistInstanceId: `ti-${seq}`,
    provider: overrides.premium ? "linkedin" : "google",
    actorId: `actor-${seq}`,
    connectedAt: new Date(2026, 0, 1 + seq++).toISOString(),
    ...overrides,
  });
  it("add-ons are never trimmed by the pool (only beyond purchased credits)", () => {
    // 1 regular + 3 add-ons, pool of 1, 3 add-on credits: nothing trims —
    // add-ons don't count toward the pool and all 3 are within credits.
    const reg = conn({ twistInstanceId: "reg", premium: false, connectedAt: "2026-01-01T00:00:00Z" });
    const a1 = conn({ twistInstanceId: "a1", premium: true, connectedAt: "2026-01-02T00:00:00Z" });
    const a2 = conn({ twistInstanceId: "a2", premium: true, connectedAt: "2026-01-03T00:00:00Z" });
    const a3 = conn({ twistInstanceId: "a3", premium: true, connectedAt: "2026-01-04T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([reg, a1, a2, a3], {
      connections: 1,
      addonCredits: 3,
    });
    expect(trimmed).toEqual([]);
  });

  it("trims the NEWEST excess regular connections, keeping the oldest; add-ons untouched", () => {
    const oldest = conn({ twistInstanceId: "oldest", premium: false, connectedAt: "2026-01-01T00:00:00Z" });
    const newer = conn({ twistInstanceId: "newer", premium: false, connectedAt: "2026-01-02T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: false, connectedAt: "2026-01-03T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([oldest, newer, newest], {
      connections: 1,
      addonCredits: 0,
    });
    // pool of 1 keeps the oldest; newer + newest are trimmed.
    expect(trimmed.map((c) => c.twistInstanceId).sort()).toEqual(["newer", "newest"]);
  });

  it("trims the NEWEST add-on beyond credits, keeping the oldest", () => {
    const old = conn({ twistInstanceId: "old", premium: true, connectedAt: "2026-01-01T00:00:00Z" });
    const newest = conn({ twistInstanceId: "newest", premium: true, connectedAt: "2026-01-02T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([old, newest], { connections: 2, addonCredits: 1 });
    expect(trimmed.map((c) => c.twistInstanceId)).toEqual(["newest"]);
  });

  it("Infinity pool + enough credits never trims", () => {
    const reg1 = conn({ twistInstanceId: "reg1", premium: false });
    const reg2 = conn({ twistInstanceId: "reg2", premium: false });
    const add = conn({ twistInstanceId: "add", premium: true });
    const trimmed = selectConnectionsToTrim([reg1, reg2, add], {
      connections: Infinity,
      addonCredits: 1,
    });
    expect(trimmed).toEqual([]);
  });
});

// getUsage drives the Connections modal's quota display. It loops over every
// team the user belongs to; the per-team connection/premium lookups must be
// batched so the query count stays flat as team membership grows.
describe.skipIf(!DATABASE_URL)("getUsage batches per-team queries", () => {
  function makeCountingDb() {
    let count = 0;
    const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 1 });
    const db = new Kysely<DB>({
      dialect: new PostgresDialect({ pool }),
      log(event) {
        if (event.level === "query") count++;
      },
    });
    return { db, getCount: () => count, reset: () => (count = 0) };
  }

  /** Insert a team and add `userId` as a member; return the new team id. */
  async function seedTeam(trx: Kysely<DB>, userId: string): Promise<number> {
    const team = await sql<{ id: string }>`
      INSERT INTO team (name) VALUES (${"Team " + randomUUID()})
      RETURNING id`.execute(trx);
    const teamId = Number(team.rows[0].id);
    await sql`INSERT INTO team_user (team_id, user_id, role)
      VALUES (${teamId}, ${userId}::uuid, 'member')`.execute(trx);
    return teamId;
  }

  /** Run getUsage for a fresh user seeded into `teamCount` teams and return the
   *  number of queries getUsage itself issued (seeding is excluded). */
  async function usageQueryCount(teamCount: number): Promise<number> {
    const { db, getCount, reset } = makeCountingDb();
    const userId = randomUUID();
    let queries = 0;
    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        for (let i = 0; i < teamCount; i++) await seedTeam(trx, userId);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        reset();
        await getUsage(trx, userId);
        queries = getCount();
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return queries;
  }

  it("query count does not grow with the number of teams", async () => {
    const oneTeam = await usageQueryCount(1);
    const fourTeams = await usageQueryCount(4);
    // Batched aggregates mean extra teams add no extra round trips.
    expect(fourTeams).toBeLessThanOrEqual(oneTeam);
  });

  it("reports the correct per-team connection count", async () => {
    const { db } = makeCountingDb();
    const userId = randomUUID();
    let usage: any;
    let teamId = 0;
    try {
      await db.transaction().execute(async (trx) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        teamId = await seedTeam(trx, userId);
        // A source twist_instance with an enabled channel = one team connection.
        const twist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, false)
          RETURNING id`.execute(trx);
        const tiId = randomUUID();
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
            'LinkedIn', ${teamId})`.execute(trx);
        await sql`INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
          VALUES (${tiId}::uuid, 'linkedin', 'LinkedIn', true)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        usage = await getUsage(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }

    const team = usage.teams.find((t: any) => Number(t.id) === teamId);
    expect(team).toBeDefined();
    expect(team.connections.count).toBe(1);
  });
});

describe.skipIf(!DATABASE_URL)("checkChannelConnectionLimit add-on admission", () => {
  async function seedAddonAndCheck(opts: {
    purchasedAddons: number;
  }): Promise<{ allowed: boolean; reason?: string }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const twistInstanceId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons,
             billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, 'free', 'active', ${opts.purchasedAddons},
            now(), now() + interval '1 month')`.execute(trx);

        const twist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id`.execute(trx);

        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, team_id)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
            'LinkedIn', null)`.execute(trx);

        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${twistInstanceId}::uuid, ${userId}::uuid, 'linkedin',
            ${randomUUID()}::uuid)`.execute(trx);

        const res = await checkChannelConnectionLimit(trx, userId, twistInstanceId);
        result = res.allowed
          ? { allowed: true }
          : { allowed: false, reason: res.error.reason };

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return result;
  }

  it("Free user WITH a spare add-on credit is allowed", async () => {
    expect(await seedAddonAndCheck({ purchasedAddons: 1 })).toEqual({ allowed: true });
  });

  it("Free user with NO add-on credit needs to buy one", async () => {
    expect(await seedAddonAndCheck({ purchasedAddons: 0 })).toEqual({
      allowed: false,
      reason: "addon_required",
    });
  });
});

describe.skipIf(!DATABASE_URL)("weighted automation capacity", () => {
  // Seeds a non-source twist + instance with the given capacity_weight for a
  // personal user and returns getPersonalTwistWeightSum. Mirrors the existing
  // seedAndCount pattern (session_replication_role=replica + Rollback).
  async function seedWeightSum(opts: { weight: number; builtin?: boolean }): Promise<number> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const twistInstanceId = randomUUID();
    let sum = -1;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const pkgId = opts.builtin
          ? "0199b6f4-ae64-7718-8a02-44716f30358f"
          : randomUUID();
        const twist = await sql<{ id: string }>`
          INSERT INTO twist (twist_package_id, environment, user_id, name, handle,
            version, is_source, premium, capacity_weight)
          VALUES (${pkgId}::uuid, 'personal', ${userId}::uuid, 'W', 'w', '1.0.0',
            false, false, ${opts.weight})
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id, draft)
          VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id}, ${userId}::uuid, 'W', null, false)`.execute(trx);
        sum = await getPersonalTwistWeightSum(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return sum;
  }

  it("sums capacity_weight of installed automations", async () => {
    expect(await seedWeightSum({ weight: 3 })).toBe(3);
  });

  it("excludes the built-in assistant (weight 0 / excluded)", async () => {
    expect(await seedWeightSum({ weight: 5, builtin: true })).toBe(0);
  });

  async function seedAndCheckCapacity(opts: {
    installedWeight: number;
    candidateWeight: number;
    twistAddonCount?: number;
  }): Promise<{ allowed: boolean; reason?: string }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO user_subscription
            (user_id, plan, status, twist_addon_count,
             billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, 'free', 'active', ${opts.twistAddonCount ?? 0},
            now(), now() + interval '1 month')`.execute(trx);
        if (opts.installedWeight > 0) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist (twist_package_id, environment, user_id, name, handle,
              version, is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid, 'I', 'i', '1.0.0',
              false, false, ${opts.installedWeight})
            RETURNING id`.execute(trx);
          await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
            VALUES (${randomUUID()}::uuid, ${twist.rows[0].id}, ${userId}::uuid, 'I', null)`.execute(trx);
        }
        const res = await checkTwistCapacity(trx, userId, null, opts.candidateWeight);
        result = res.allowed ? { allowed: true } : { allowed: false, reason: res.error.reason };
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return result;
  }

  it("Free: first automation (weight 1) fits capacity 1", async () => {
    expect(await seedAndCheckCapacity({ installedWeight: 0, candidateWeight: 1 })).toEqual({ allowed: true });
  });

  it("Free: a second automation exceeds capacity 1 → twist_addon_required", async () => {
    expect(await seedAndCheckCapacity({ installedWeight: 1, candidateWeight: 1 })).toEqual({
      allowed: false,
      reason: "twist_addon_required",
    });
  });

  it("Free: a weight-2 automation alone exceeds capacity 1", async () => {
    expect(await seedAndCheckCapacity({ installedWeight: 0, candidateWeight: 2 })).toEqual({
      allowed: false,
      reason: "twist_addon_required",
    });
  });

  it("a purchased twist-add-on block (+20) lets it fit", async () => {
    expect(
      await seedAndCheckCapacity({ installedWeight: 1, candidateWeight: 1, twistAddonCount: 1 })
    ).toEqual({ allowed: true });
  });

  it("lapsed team (status=canceled, plan=team) gets pool 0 → team_block_required", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        // Create a team
        const team = await sql<{ id: string }>`
          INSERT INTO team (name) VALUES ('Lapsed Team')
          RETURNING id`.execute(trx);
        const teamId = Number(team.rows[0].id);
        // Seed a team_subscription with canceled status but plan='team'
        await sql`INSERT INTO team_subscription
            (team_id, plan, status, connection_group_quantity, twist_addon_count,
             billing_cycle_start, billing_cycle_end)
          VALUES (${teamId}, 'team', 'canceled', 1, 0,
            now() - interval '2 months', now() - interval '1 day')`.execute(trx);
        // A candidate with weight 1 should be rejected (capacity = 0 for lapsed)
        const res = await checkTwistCapacity(trx, userId, String(teamId), 1);
        result = res.allowed ? { allowed: true } : { allowed: false, reason: res.error.reason };
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(result).toEqual({ allowed: false, reason: "team_block_required" });
  });
});

describe.skipIf(!DATABASE_URL)("getBillableConnectionAddonCount", () => {
  /**
   * Seeds a user_subscription of `plan` + `regular` non-premium source twist
   * instances + `addonRequired` premium source twist instances, each with an
   * enabled channel, inside a rolled-back transaction. Returns the billable
   * connection add-on count for the seeded user.
   */
  async function seedAndBillable(opts: {
    plan: PlanKey;
    regular: number;
    addonRequired: number;
  }): Promise<number> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let result = -1;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, ${opts.plan}, 'active',
            now(), now() + interval '1 month')`.execute(trx);

        // Seed regular (non-premium) connections
        for (let i = 0; i < opts.regular; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        // Seed add-on-required (premium) connections
        for (let i = 0; i < opts.addonRequired; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`LinkedIn ${i}`}, ${`linkedin${i}`}, '1.0.0', true, true)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`LinkedIn ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`linkedin${i}`}, ${`LinkedIn ${i}`}, true)`.execute(trx);
        }

        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        result = await getBillableConnectionAddonCount(trx, { userId });
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return result;
  }

  it("Free: 3 regular + 1 add-on-required → (3−2) + 1 = 2 billable", async () => {
    expect(await seedAndBillable({ plan: "free", regular: 3, addonRequired: 1 })).toBe(2);
  });
  it("Free: 2 regular (at pool) + 0 add-on → 0 billable", async () => {
    expect(await seedAndBillable({ plan: "free", regular: 2, addonRequired: 0 })).toBe(0);
  });
  it("Pro: 5 regular + 2 add-on-required → 0 + 2 = 2 billable (∞ pool)", async () => {
    expect(await seedAndBillable({ plan: "pro", regular: 5, addonRequired: 2 })).toBe(2);
  });
});

describe.skipIf(!DATABASE_URL)("checkChannelConnectionLimit regular-beyond-pool", () => {
  /**
   * Seeds a Free user_subscription with `premium_connection_addons` credits,
   * `existingRegular` enabled non-premium connections, and a NEW non-premium
   * twist instance under test (no channel yet). Returns allowed/reason from
   * checkChannelConnectionLimit for the new instance. Transaction is rolled back.
   */
  async function seedRegularAndCheck(opts: {
    existingRegular: number;
    purchasedAddons: number;
  }): Promise<{ allowed: boolean; reason?: string }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const newTwistInstanceId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons,
             billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, 'free', 'active', ${opts.purchasedAddons},
            now(), now() + interval '1 month')`.execute(trx);

        // Seed existing regular (non-premium) connections with enabled channels
        for (let i = 0; i < opts.existingRegular; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        // Seed the new (candidate) regular connection — no channel yet
        const newTwist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'NewConn', 'newconn', '1.0.0', true, false)
          RETURNING id`.execute(trx);

        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, team_id)
          VALUES (${newTwistInstanceId}::uuid, ${newTwist.rows[0].id}, ${userId}::uuid,
            'NewConn', null)`.execute(trx);

        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${newTwistInstanceId}::uuid, ${userId}::uuid, 'newconn',
            ${randomUUID()}::uuid)`.execute(trx);

        const res = await checkChannelConnectionLimit(trx, userId, newTwistInstanceId);
        result = res.allowed
          ? { allowed: true }
          : { allowed: false, reason: res.error.reason };

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return result;
  }

  it("Free: 3rd regular connection with NO add-on credit → addon_required", async () => {
    // seed 2 enabled regular connections (at pool) + premium_connection_addons=0,
    // then check a NEW regular connection instance → adding it makes billable 1 > 0.
    expect(await seedRegularAndCheck({ existingRegular: 2, purchasedAddons: 0 }))
      .toEqual({ allowed: false, reason: "addon_required" });
  });
  it("Free: 3rd regular connection WITH 1 add-on credit → allowed", async () => {
    expect(await seedRegularAndCheck({ existingRegular: 2, purchasedAddons: 1 }))
      .toEqual({ allowed: true });
  });
  it("Free: 2nd regular connection (within pool) → allowed, no add-on needed", async () => {
    expect(await seedRegularAndCheck({ existingRegular: 1, purchasedAddons: 0 }))
      .toEqual({ allowed: true });
  });
});

// Issue 1 regression: the isAddon (premium) enable gate must use the billable
// formula, not the premium-only count. A user who spent credits on over-pool
// regulars must NOT be able to add a premium connector for free.
describe.skipIf(!DATABASE_URL)("checkChannelConnectionLimit isAddon billable gate", () => {
  /**
   * Seeds a Free user with `purchasedAddons` credits, `existingRegular` enabled
   * non-premium connections (may exceed pool), then checks whether a NEW premium
   * (add-on-required) connection instance can be enabled.
   */
  async function seedIsAddonCheckWithRegulars(opts: {
    existingRegular: number;
    purchasedAddons: number;
  }): Promise<{ allowed: boolean; reason?: string }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const premiumTwistInstanceId = randomUUID();
    let result: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons,
             billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, 'free', 'active', ${opts.purchasedAddons},
            now(), now() + interval '1 month')`.execute(trx);

        // Seed existing regular (non-premium) connections with enabled channels.
        // These count toward getPersonalConnectionCount and push the billable
        // formula when they exceed the pool (pool=2 for Free).
        for (let i = 0; i < opts.existingRegular; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        // Seed the premium (add-on-required) candidate — no channel yet,
        // but a twist_instance_connection so the limit check runs.
        const premiumTwist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'LinkedIn', 'linkedin', '1.0.0', true, true)
          RETURNING id`.execute(trx);

        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, team_id)
          VALUES (${premiumTwistInstanceId}::uuid, ${premiumTwist.rows[0].id},
            ${userId}::uuid, 'LinkedIn', null)`.execute(trx);

        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${premiumTwistInstanceId}::uuid, ${userId}::uuid, 'linkedin',
            ${randomUUID()}::uuid)`.execute(trx);

        const res = await checkChannelConnectionLimit(trx, userId, premiumTwistInstanceId);
        result = res.allowed
          ? { allowed: true }
          : { allowed: false, reason: res.error.reason };

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
    return result;
  }

  it("Free: 3 regulars (over pool) + 1 credit → premium enable BLOCKED (credit is spent)", async () => {
    // pool=2, credits=1, 3 regulars → billable already 1; adding premium makes
    // pendingBillable=2 > purchased=1 → addon_required.
    // Before the fix this was wrongly allowed (old gate: addonCount(0) >= purchased(1) → false).
    expect(
      await seedIsAddonCheckWithRegulars({ existingRegular: 3, purchasedAddons: 1 })
    ).toEqual({ allowed: false, reason: "addon_required" });
  });

  it("Free: 3 regulars (over pool) + 2 credits → premium enable ALLOWED", async () => {
    // pool=2, credits=2, 3 regulars → billable 1; pendingBillable=2 ≤ purchased=2 → allowed.
    expect(
      await seedIsAddonCheckWithRegulars({ existingRegular: 3, purchasedAddons: 2 })
    ).toEqual({ allowed: true });
  });

  it("Free: 2 regulars (at pool) + 1 credit → premium enable ALLOWED", async () => {
    // pool=2, credits=1, 2 regulars → billable 0; pendingBillable=1 ≤ purchased=1 → allowed.
    expect(
      await seedIsAddonCheckWithRegulars({ existingRegular: 2, purchasedAddons: 1 })
    ).toEqual({ allowed: true });
  });
});

// Issue 1b regression: personal.premium.count must reflect the BILLABLE count
// (overPool regulars + premium), not just the raw premium-connection count.
describe.skipIf(!DATABASE_URL)("getUsage personal.premium.count is billable", () => {
  it("Free: 3 regulars (over pool by 1) + 0 premium → premium.count = 1 (billable)", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let usage: any;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons,
             billing_cycle_start, billing_cycle_end)
          VALUES (${userId}::uuid, 'free', 'active', 0,
            now(), now() + interval '1 month')`.execute(trx);

        // Seed 3 regular (non-premium) connections — over the Free pool of 2.
        for (let i = 0; i < 3; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        usage = await getUsage(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }

    // 3 regulars, pool=2 → overPool=1, no premium → billable=1.
    // Before the fix premium.count was 0 (raw premium count only).
    expect(usage.personal.premium.count).toBe(1);
  });
});

// getUsage personal payload must NOT include an 'ai' field — AI limits are now
// an unpublished internal cap managed in ai-limits.ts, not surfaced to clients.
describe.skipIf(!DATABASE_URL)("getUsage personal payload excludes AI limits", () => {
  it("personal.ai is absent from the getUsage response", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let usage: any;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        usage = await getUsage(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(usage.personal.ai).toBeUndefined();
  });
});

// ─── pricing field exposed in getUsage ───────────────────────────────────────
describe.skipIf(!DATABASE_URL)("getUsage exposes web add-on prices", () => {
  it("pricing.connectionAddonPrice === 5 and pricing.twistAddonPrice === 10", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let usage: any;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
        usage = await getUsage(trx, userId);
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    expect(usage.pricing.connectionAddonPrice).toBe(5);
    expect(usage.pricing.twistAddonPrice).toBe(10);
  });
});

// ─── 30-day trial: unlimited connections (connections ONLY) ───────────────────
describe.skipIf(!DATABASE_URL)("30-day trial — unlimited connections (connections only)", () => {
  /**
   * Seeds a Free user_subscription with optional `trial_ends_at`, `existingRegular`
   * enabled regular connections, and a NEW non-premium candidate twist instance.
   * Runs checkChannelConnectionLimit, getBillableConnectionAddonCount, and getUsage
   * inside one rolled-back transaction and returns the key values under test.
   */
  async function seedTrialUser(opts: {
    trialEndsAt: string | null;
    existingRegular: number;
  }): Promise<{
    checkResult: { allowed: boolean; reason?: string };
    billable: number;
    usageConnectionsLimit: number | null;
    usageTwistsLimit: number;
  }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const newTwistInstanceId = randomUUID();
    let checkResult: { allowed: boolean; reason?: string } = { allowed: false };
    let billable = -1;
    let usageConnectionsLimit: number | null = -1;
    let usageTwistsLimit = -1;
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        await sql`INSERT INTO user_subscription
            (user_id, plan, status, premium_connection_addons,
             billing_cycle_start, billing_cycle_end, trial_ends_at)
          VALUES (${userId}::uuid, 'free', 'active', 0,
            now(), now() + interval '1 month', ${opts.trialEndsAt})`.execute(trx);

        // Seed existing regular connections with enabled channels
        for (let i = 0; i < opts.existingRegular; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, null)`.execute(trx);
          await sql`INSERT INTO channel
              (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        // Seed the candidate new regular connection (no channel yet)
        const newTwist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'NewConn', 'newconn', '1.0.0', true, false)
          RETURNING id`.execute(trx);
        await sql`INSERT INTO twist_instance
            (id, twist_id, owner_id, name, team_id)
          VALUES (${newTwistInstanceId}::uuid, ${newTwist.rows[0].id}, ${userId}::uuid,
            'NewConn', null)`.execute(trx);
        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${newTwistInstanceId}::uuid, ${userId}::uuid, 'newconn',
            ${randomUUID()}::uuid)`.execute(trx);

        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        const res = await checkChannelConnectionLimit(trx, userId, newTwistInstanceId);
        checkResult = res.allowed
          ? { allowed: true }
          : { allowed: false, reason: res.error.reason };

        billable = await getBillableConnectionAddonCount(trx, { userId });

        const usage = await getUsage(trx, userId);
        usageConnectionsLimit = usage.personal.connections.limit;
        usageTwistsLimit = usage.personal.twists.limit;

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return { checkResult, billable, usageConnectionsLimit, usageTwistsLimit };
  }

  it("ACTIVE trial: 3rd regular connection → allowed (unlimited pool)", async () => {
    const { checkResult } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 2,
    });
    expect(checkResult).toEqual({ allowed: true });
  });

  it("EXPIRED trial: 3rd regular connection → addon_required (pool=2)", async () => {
    const { checkResult } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() - 1 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 2,
    });
    expect(checkResult).toEqual({ allowed: false, reason: "addon_required" });
  });

  it("NULL trial_ends_at: 3rd regular connection → addon_required (pool=2)", async () => {
    const { checkResult } = await seedTrialUser({
      trialEndsAt: null,
      existingRegular: 2,
    });
    expect(checkResult).toEqual({ allowed: false, reason: "addon_required" });
  });

  it("ACTIVE trial: getBillableConnectionAddonCount → 0 (∞ pool, 3 regular but no over-pool)", async () => {
    const { billable } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 3,
    });
    expect(billable).toBe(0);
  });

  it("EXPIRED trial: getBillableConnectionAddonCount → 1 (3 regular − Free pool 2)", async () => {
    const { billable } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() - 1 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 3,
    });
    expect(billable).toBe(1);
  });

  it("ACTIVE trial: getUsage connections limit → null (unlimited)", async () => {
    const { usageConnectionsLimit } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 2,
    });
    expect(usageConnectionsLimit).toBeNull();
  });

  it("EXPIRED trial: getUsage connections limit → 2 (Free pool)", async () => {
    const { usageConnectionsLimit } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() - 1 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 2,
    });
    expect(usageConnectionsLimit).toBe(2);
  });

  it("ACTIVE trial: twistCapacity stays Free=1 (trial does NOT affect twists)", async () => {
    const { usageTwistsLimit } = await seedTrialUser({
      trialEndsAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
      existingRegular: 0,
    });
    expect(usageTwistsLimit).toBe(1); // Free twistCapacity = 1, no add-ons
  });
});

// Issue 2: selectConnectionsToTrim credit spill-over to regulars.
describe("selectConnectionsToTrim credit spill-over (Issue 2)", () => {
  let seq = 0;
  const conn = (overrides: Partial<TrimmableConnection> & { premium: boolean }): TrimmableConnection => ({
    twistInstanceId: `spill-ti-${seq}`,
    provider: overrides.premium ? "linkedin" : "google",
    actorId: `spill-actor-${seq}`,
    connectedAt: new Date(2026, 3, 1 + seq++).toISOString(),
    ...overrides,
  });

  it("pool 2 + 1 credit + 0 premium + 3 regulars → trims nothing (credit extends pool)", () => {
    // Regular pool=2, no premium → creditsForRegular=1, keep regulars.slice(3) = nothing.
    const r1 = conn({ twistInstanceId: "spill-r1", premium: false, connectedAt: "2026-04-01T00:00:00Z" });
    const r2 = conn({ twistInstanceId: "spill-r2", premium: false, connectedAt: "2026-04-02T00:00:00Z" });
    const r3 = conn({ twistInstanceId: "spill-r3", premium: false, connectedAt: "2026-04-03T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([r1, r2, r3], { connections: 2, addonCredits: 1 });
    expect(trimmed).toEqual([]);
  });

  it("pool 2 + 1 credit + 1 premium + 3 regulars → trims newest regular only", () => {
    // 1 premium consumes the 1 credit; creditsForRegular=0; regulars kept up to pool=2.
    const prem = conn({ twistInstanceId: "spill-prem", premium: true, connectedAt: "2026-04-01T00:00:00Z" });
    const r1 = conn({ twistInstanceId: "spill-r1b", premium: false, connectedAt: "2026-04-02T00:00:00Z" });
    const r2 = conn({ twistInstanceId: "spill-r2b", premium: false, connectedAt: "2026-04-03T00:00:00Z" });
    const r3 = conn({ twistInstanceId: "spill-r3b", premium: false, connectedAt: "2026-04-04T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([prem, r1, r2, r3], { connections: 2, addonCredits: 1 });
    // premium kept; regulars: oldest r1+r2 kept, r3 trimmed.
    expect(trimmed.map((c) => c.twistInstanceId)).toEqual(["spill-r3b"]);
  });

  it("pool 2 + 2 credits + 1 premium + 3 regulars → trims nothing (1 credit spills)", () => {
    // 1 premium consumes 1 credit; creditsForRegular=1; keep regulars up to 3 → no trim.
    const prem = conn({ twistInstanceId: "spill-prem2", premium: true, connectedAt: "2026-04-01T00:00:00Z" });
    const r1 = conn({ twistInstanceId: "spill-r1c", premium: false, connectedAt: "2026-04-02T00:00:00Z" });
    const r2 = conn({ twistInstanceId: "spill-r2c", premium: false, connectedAt: "2026-04-03T00:00:00Z" });
    const r3 = conn({ twistInstanceId: "spill-r3c", premium: false, connectedAt: "2026-04-04T00:00:00Z" });
    const trimmed = selectConnectionsToTrim([prem, r1, r2, r3], { connections: 2, addonCredits: 2 });
    expect(trimmed).toEqual([]);
  });
});

describe("pricing constants wired", () => {
  it("Pro includes 3 twist automations", () => {
    expect(PLAN_LIMITS.pro.twistCapacity).toBe(3);
    expect(PLAN_LIMITS.free.twistCapacity).toBe(1);
  });
  it("twist add-on blocks are packs of 5", () => {
    // base 3 (Pro), weightSum 8 → overflow 5 → 1 block of 5
    expect(computeTwistBlocksNeeded(8, 3)).toBe(1);
    // overflow 6 → 2 blocks
    expect(computeTwistBlocksNeeded(9, 3)).toBe(2);
    // within capacity → 0
    expect(computeTwistBlocksNeeded(3, 3)).toBe(0);
    // pendingWeight included
    expect(computeTwistBlocksNeeded(3, 3, 5)).toBe(1);
  });
});

// ─── Team interchangeable slot pool (Task 3) ─────────────────────────────────
// Regular (non-premium) connections + twist weight share the pool:
// pool = TEAM_SLOTS_PER_GROUP × connection_group_quantity.
// Over-pool returns team_block_required; under-pool is allowed.
describe.skipIf(!DATABASE_URL)("Team interchangeable slot pool", () => {
  /**
   * Seeds a team with an active 'team' subscription (1 block = pool of 50),
   * seeds `regularCount` regular connections + a twist with `twistWeight`, then
   * returns allowed/reason for checkTwistCapacity(candidateWeight) and
   * checkChannelConnectionLimit for a new regular connector.
   * All inside a rolled-back transaction.
   */
  async function seedTeamPoolAndCheck(opts: {
    regularCount: number;
    twistWeight: number;
    candidateTwistWeight: number;
  }): Promise<{
    twistCheck: { allowed: boolean; reason?: string };
    connCheck: { allowed: boolean; reason?: string };
  }> {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    let twistCheck: { allowed: boolean; reason?: string } = { allowed: false };
    let connCheck: { allowed: boolean; reason?: string } = { allowed: false };
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        // Create team and add user as admin
        const teamRow = await sql<{ id: string }>`
          INSERT INTO team (name) VALUES ('Test Team')
          RETURNING id`.execute(trx);
        const teamId = Number(teamRow.rows[0].id);
        await sql`INSERT INTO team_user (team_id, user_id, role)
          VALUES (${teamId}, ${userId}::uuid, 'admin')`.execute(trx);

        // Active team subscription: plan='team', 1 block → pool = 50
        await sql`INSERT INTO team_subscription
            (team_id, plan, status, connection_group_quantity,
             billing_cycle_start, billing_cycle_end)
          VALUES (${teamId}, 'team', 'active', 1,
            now(), now() + interval '1 month')`.execute(trx);

        // Seed regular connections (each counts as 1 slot)
        for (let i = 0; i < opts.regularCount; i++) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              ${`Google ${i}`}, ${`google${i}`}, '1.0.0', true, false, 0)
            RETURNING id`.execute(trx);
          const tiId = randomUUID();
          await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
            VALUES (${tiId}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              ${`Google ${i}`}, ${teamId})`.execute(trx);
          await sql`INSERT INTO channel (twist_instance_id, channel_id, title, enabled)
            VALUES (${tiId}::uuid, ${`google${i}`}, ${`Google ${i}`}, true)`.execute(trx);
        }

        // Seed a twist with capacity_weight (counts toward the slot pool)
        if (opts.twistWeight > 0) {
          const twist = await sql<{ id: string }>`
            INSERT INTO twist
              (twist_package_id, environment, user_id, name, handle, version,
               is_source, premium, capacity_weight)
            VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
              'Automation', 'auto', '1.0.0', false, false, ${opts.twistWeight})
            RETURNING id`.execute(trx);
          await sql`INSERT INTO twist_instance
              (id, twist_id, owner_id, name, team_id, draft)
            VALUES (${randomUUID()}::uuid, ${twist.rows[0].id}, ${userId}::uuid,
              'Automation', ${teamId}, false)`.execute(trx);
        }

        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        // Check twist capacity for the candidate twist
        const twistRes = await checkTwistCapacity(trx, userId, String(teamId), opts.candidateTwistWeight);
        twistCheck = twistRes.allowed ? { allowed: true } : { allowed: false, reason: twistRes.error.reason };

        // Seed a new regular connector (no channel yet) for the connection check
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const newTwist = await sql<{ id: string }>`
          INSERT INTO twist
            (twist_package_id, environment, user_id, name, handle, version,
             is_source, premium, capacity_weight)
          VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
            'NewConn', 'newconn', '1.0.0', true, false, 0)
          RETURNING id`.execute(trx);
        const newTiId = randomUUID();
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id)
          VALUES (${newTiId}::uuid, ${newTwist.rows[0].id}, ${userId}::uuid,
            'NewConn', ${teamId})`.execute(trx);
        await sql`INSERT INTO twist_instance_connection
            (twist_instance_id, user_id, provider, actor_id)
          VALUES (${newTiId}::uuid, ${userId}::uuid, 'newconn',
            ${randomUUID()}::uuid)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        const connRes = await checkChannelConnectionLimit(trx, userId, newTiId);
        connCheck = connRes.allowed ? { allowed: true } : { allowed: false, reason: connRes.error.reason };

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
    return { twistCheck, connCheck };
  }

  it("connections + twist weight share the 50-slot pool: full pool blocks with team_block_required", async () => {
    // 49 regular connections + 1 twist weight = 50 used (pool full).
    // Candidate twist weight 1 → overflow → team_block_required.
    // New regular connection → overflow → team_block_required.
    const { twistCheck, connCheck } = await seedTeamPoolAndCheck({
      regularCount: 49,
      twistWeight: 1,
      candidateTwistWeight: 1,
    });
    expect(twistCheck).toEqual({ allowed: false, reason: "team_block_required" });
    expect(connCheck).toEqual({ allowed: false, reason: "team_block_required" });
  });

  it("connections + twist weight under pool: candidate is allowed", async () => {
    // 48 regular connections + 1 twist weight = 49 used (1 slot free).
    // Candidate twist weight 1 → fits → allowed.
    // New regular connection → fits → allowed.
    const { twistCheck, connCheck } = await seedTeamPoolAndCheck({
      regularCount: 48,
      twistWeight: 1,
      candidateTwistWeight: 1,
    });
    expect(twistCheck).toEqual({ allowed: true });
    expect(connCheck).toEqual({ allowed: true });
  });

  it("connections alone filling the 50-slot pool blocks a new twist", async () => {
    // 50 regular connections, no twist weight → pool full.
    // Candidate twist weight 1 → blocked.
    const { twistCheck } = await seedTeamPoolAndCheck({
      regularCount: 50,
      twistWeight: 0,
      candidateTwistWeight: 1,
    });
    expect(twistCheck).toEqual({ allowed: false, reason: "team_block_required" });
  });

  it("twist weight alone filling the 50-slot pool blocks a new connection", async () => {
    // 0 regular connections, twist weight 50 → pool full.
    // New regular connection → blocked.
    const { connCheck } = await seedTeamPoolAndCheck({
      regularCount: 0,
      twistWeight: 50,
      candidateTwistWeight: 0,
    });
    expect(connCheck).toEqual({ allowed: false, reason: "team_block_required" });
  });
});
