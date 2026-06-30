/**
 * Regression test for the link-removal sync fix.
 *
 * `archive_links` must ALWAYS soft-delete (set link.archived_at), even for the
 * whole-instance uninstall case, so every removed link emits a durable per-row
 * tombstone via `user.link_redacted` that the client uses to hard-delete the
 * link + its schedules. The prior design hard-DELETED links on uninstall and
 * relied on a fire-once client purge keyed on `twist_instance.archived_at`,
 * which raced sync-cursor ordering and stranded straggler links/schedules
 * (manifesting as duplicate recurring events on the agenda).
 *
 * Critically, `user.link_redacted` must still emit a soft-deleted link AFTER
 * its owning twist_instance is archived (uninstall soft-archives the instance,
 * not hard-delete), so the tombstone survives the instance going away.
 *
 * Each test seeds synthetic rows inside a transaction with triggers/FK checks
 * disabled (`session_replication_role = replica`) and throws `Rollback` so the
 * DB is left pristine. Skipped when DATABASE_URL is absent (CI without a DB).
 */
import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { rpc } from "../rpc";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/** Seed a source connector + one calendar-style link with a recurring schedule. */
async function withScenario(
  test: (args: {
    trx: Kysely<DB>;
    userId: string;
    instanceId: string;
    threadId: string;
    linkId: string;
    scheduleId: string;
  }) => Promise<void>
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      const userId = randomUUID();
      const instanceId = randomUUID();
      const threadId = randomUUID();
      const linkId = randomUUID();
      const scheduleId = randomUUID();
      // twist.id is a GENERATED ALWAYS bigint identity — pick a high synthetic
      // value and override. A `personal` twist must carry user_id (twist_owner_check).
      const twistId = 990000000 + Math.floor(Math.random() * 1_000_000);

      await sql`INSERT INTO "user" (id, email) VALUES (${userId}, ${`al-${userId}@example.com`})`.execute(
        trx
      );
      await sql`
        INSERT INTO twist (id, name, version, twist_package_id, handle, is_source, environment, user_id)
        OVERRIDING SYSTEM VALUE
        VALUES (${twistId}, 'TestCal', '1.0.0', ${randomUUID()}, ${`testcal_${twistId}`}, true, 'personal', ${userId})
      `.execute(trx);
      await sql`
        INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (${instanceId}, ${twistId}, ${userId}, 'Test Instance')
      `.execute(trx);
      await sql`
        INSERT INTO thread (id, created_by, title)
        VALUES (${threadId}, ${instanceId}, 'Movie Night')
      `.execute(trx);
      await sql`
        INSERT INTO link (id, thread_id, created_by, twist_id, source)
        VALUES (${linkId}, ${threadId}, ${instanceId}, ${twistId}, 'test:evt1')
      `.execute(trx);
      await sql`
        INSERT INTO schedule (id, link_id, at, recurrence_rule, duration)
        VALUES (${scheduleId}, ${linkId}, tstzrange(now(), NULL), 'FREQ=WEEKLY', interval '1 hour')
      `.execute(trx);

      await test({ trx, userId, instanceId, threadId, linkId, scheduleId });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

async function linkRow(trx: Kysely<DB>, linkId: string) {
  return sql<{ archived_at: Date | null }>`
    SELECT archived_at FROM link WHERE id = ${linkId}
  `
    .execute(trx)
    .then((r) => r.rows[0]);
}

async function countScalar(trx: Kysely<DB>, query: ReturnType<typeof sql>) {
  const r = await sql<{ n: number }>`SELECT count(*)::int AS n FROM (${query}) s`.execute(
    trx
  );
  return Number(r.rows[0]?.n ?? 0);
}

describe.skipIf(!DATABASE_URL)("archive_links always soft-deletes", () => {
  it("whole-instance uninstall soft-archives the link (does not hard-delete) and keeps schedules", async () => {
    await withScenario(async ({ trx, instanceId, linkId, scheduleId }) => {
      await rpc(trx, "archive_links", {
        p_created_by: instanceId,
        p_filter: {},
      });

      const link = await linkRow(trx, linkId);
      // Row survives — NOT a bare DELETE.
      expect(link).toBeDefined();
      // ...with archived_at set (soft delete).
      expect(link?.archived_at).not.toBeNull();

      // The link's schedule survives server-side (the client cascade-deletes it
      // locally when it processes the link tombstone).
      const schedules = await sql<{ n: number }>`
        SELECT count(*)::int AS n FROM schedule WHERE id = ${scheduleId}
      `.execute(trx);
      expect(Number(schedules.rows[0]?.n)).toBe(1);
    });
  });

  it("emits a user.link_redacted tombstone even after the owning instance is archived", async () => {
    await withScenario(async ({ trx, userId, instanceId, linkId }) => {
      await rpc(trx, "archive_links", {
        p_created_by: instanceId,
        p_filter: {},
      });

      // Simulate deleteTwist soft-archiving the instance (uninstall).
      await sql`UPDATE twist_instance SET archived_at = now() WHERE id = ${instanceId}`.execute(
        trx
      );

      // The redacted view delivers the per-row tombstone to the owner even
      // though the instance is archived — this is the load-bearing fix.
      const redacted = await countScalar(
        trx,
        sql`SELECT 1 FROM "user".link_redacted WHERE id = ${linkId} AND user_id = ${userId} AND revoked`
      );
      expect(redacted).toBe(1);

      // ...and it must NOT appear in the live link view.
      const live = await countScalar(
        trx,
        sql`SELECT 1 FROM "user".link WHERE id = ${linkId} AND user_id = ${userId}`
      );
      expect(live).toBe(0);
    });
  });
});
