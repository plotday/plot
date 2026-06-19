import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  getPersonalConnectionCount,
  getTeamConnectionCount,
  selectConnectionsToTrim,
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
      // constraint (user_id set, publisher_id null) and is all the count
      // queries inspect (is_source = true, premium = false).
      const twist = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, environment, user_id, name, handle, version,
           is_source, premium)
        VALUES (${randomUUID()}::uuid, 'personal', ${userId}::uuid,
          'LinkedIn', 'linkedin', '1.0.0', true, false)
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
  const ids = (cs: TrimmableConnection[]) =>
    cs.map((c) => c.twistInstanceId).sort();

  it("trims the lone LinkedIn premium connection on Pro→Free downgrade", () => {
    // The cost bug: Free blocks premium, but a single premium connection sits
    // within the regular connection budget (2) so a count-only trim keeps it.
    const linkedin = conn({ twistInstanceId: "linkedin", premium: true });
    const trimmed = selectConnectionsToTrim([linkedin], {
      connections: 2,
      premium: { type: "blocked" },
    });
    expect(ids(trimmed)).toEqual(["linkedin"]);
  });

  it("blocked policy trims every premium connection, keeps regular within limit", () => {
    const reg1 = conn({ twistInstanceId: "reg1", premium: false });
    const reg2 = conn({ twistInstanceId: "reg2", premium: false });
    const prem1 = conn({ twistInstanceId: "prem1", premium: true });
    const prem2 = conn({ twistInstanceId: "prem2", premium: true });
    const trimmed = selectConnectionsToTrim([reg1, reg2, prem1, prem2], {
      connections: 5,
      premium: { type: "blocked" },
    });
    expect(ids(trimmed)).toEqual(["prem1", "prem2"]);
  });

  it("counts premium separately from the regular pool — a regular within limit survives", () => {
    // 2 regular + 1 premium = 3 total. Old count-only logic (offset 2 over all)
    // would trim one. Premium-aware logic keeps both regular (≤2) and trims only
    // the blocked premium.
    const reg1 = conn({ twistInstanceId: "reg1", premium: false });
    const reg2 = conn({ twistInstanceId: "reg2", premium: false });
    const prem = conn({ twistInstanceId: "prem", premium: true });
    const trimmed = selectConnectionsToTrim([reg1, reg2, prem], {
      connections: 2,
      premium: { type: "blocked" },
    });
    expect(ids(trimmed)).toEqual(["prem"]);
  });

  it("trims the OLDEST excess regular connections, keeping the newest", () => {
    const oldest = conn({
      twistInstanceId: "oldest",
      premium: false,
      connectedAt: "2026-01-01T00:00:00Z",
    });
    const mid = conn({
      twistInstanceId: "mid",
      premium: false,
      connectedAt: "2026-02-01T00:00:00Z",
    });
    const newest = conn({
      twistInstanceId: "newest",
      premium: false,
      connectedAt: "2026-03-01T00:00:00Z",
    });
    const trimmed = selectConnectionsToTrim([oldest, mid, newest], {
      connections: 2,
      premium: { type: "blocked" },
    });
    expect(ids(trimmed)).toEqual(["oldest"]);
  });

  it("credits policy keeps the newest `included + addons` premium, trims older", () => {
    const old = conn({
      twistInstanceId: "old",
      premium: true,
      connectedAt: "2026-01-01T00:00:00Z",
    });
    const newer = conn({
      twistInstanceId: "newer",
      premium: true,
      connectedAt: "2026-02-01T00:00:00Z",
    });
    const newest = conn({
      twistInstanceId: "newest",
      premium: true,
      connectedAt: "2026-03-01T00:00:00Z",
    });
    const trimmed = selectConnectionsToTrim([old, newer, newest], {
      connections: Infinity,
      premium: { type: "credits", included: 1 },
      premiumAddons: 1,
    });
    // included(1) + addons(1) = keep 2 newest; trim the oldest.
    expect(ids(trimmed)).toEqual(["old"]);
  });

  it("Infinity connection budget never trims regular connections", () => {
    const reg1 = conn({ twistInstanceId: "reg1", premium: false });
    const reg2 = conn({ twistInstanceId: "reg2", premium: false });
    const prem = conn({ twistInstanceId: "prem", premium: true });
    const trimmed = selectConnectionsToTrim([reg1, reg2, prem], {
      connections: Infinity,
      premium: { type: "credits", included: 1 },
    });
    expect(ids(trimmed)).toEqual([]);
  });

  it("weighted policy (team) leaves premium connections intact", () => {
    const prem1 = conn({ twistInstanceId: "prem1", premium: true });
    const prem2 = conn({ twistInstanceId: "prem2", premium: true });
    const trimmed = selectConnectionsToTrim([prem1, prem2], {
      connections: Infinity,
      premium: { type: "weighted", weightAsRegular: 3 },
    });
    expect(ids(trimmed)).toEqual([]);
  });

  it("returns nothing for an empty connection list", () => {
    expect(
      selectConnectionsToTrim([], {
        connections: 2,
        premium: { type: "blocked" },
      })
    ).toEqual([]);
  });
});
