import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { reactionCapabilitiesCell } from "./deployment";

const DATABASE_URL = process.env.DATABASE_URL;

// These tests touch the local Postgres (worktree port via DATABASE_URL).
// Skip when no DB is configured so CI without a DB stays green.
const describeDb = DATABASE_URL ? describe : describe.skip;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Insert a twist row exactly the way deployTwist's INSERT branch does for the
 * reaction_capabilities column (via the shared reactionCapabilitiesCell
 * mapper), then read the persisted jsonb value back from the real DB.
 *
 * Proves the contract: the deploy write maps the connector metadata field
 * `reactionCapabilities` onto the twist row's `reaction_capabilities` column.
 */
async function insertAndReadBack(reactionCapabilities: unknown): Promise<unknown> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const twistPackageId = randomUUID();
  let captured: unknown;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const row = await trx
        .insertInto("twist")
        .values({
          twist_package_id: twistPackageId,
          // Personal env requires user_id (twist_owner_check). FK triggers are
          // disabled via session_replication_role = replica, so a bare uuid is fine.
          environment: "personal",
          user_id: randomUUID(),
          name: "Reaction Test Connector",
          handle: "reaction-test",
          version: Date.now().toString(),
          reaction_capabilities: reactionCapabilitiesCell(reactionCapabilities),
        })
        .returning("reaction_capabilities")
        .executeTakeFirstOrThrow();
      captured = row.reaction_capabilities;
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured;
}

describeDb("deployTwist reaction_capabilities write", () => {
  it("persists a connector's reactionCapabilities onto the twist row", async () => {
    const caps = { mode: "fixed", allowed: ["👍"] };
    const stored = await insertAndReadBack(caps);
    // jsonb round-trips as a parsed object
    const parsed = typeof stored === "string" ? JSON.parse(stored) : stored;
    expect(parsed).toEqual({ mode: "fixed", allowed: ["👍"] });
  });

  it("writes null when the connector declares no reactionCapabilities", async () => {
    const stored = await insertAndReadBack(null);
    expect(stored).toBeNull();
  });
});
