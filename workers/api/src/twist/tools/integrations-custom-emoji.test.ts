import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { Integrations } from "./integrations";

const DATABASE_URL = process.env.DATABASE_URL;

// These tests touch the local Postgres (worktree port via DATABASE_URL).
// Skip when no DB is configured so CI without a DB stays green.
const describeDb = DATABASE_URL ? describe : describe.skip;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

/**
 * Minimal stub for the CALLBACKS Durable Object namespace. saveCustomEmoji
 * never touches callbacks, but the Integrations constructor resolves a stub
 * via `env.CALLBACKS.idFromName(...).get(...)`.
 */
const callbacksStub = {
  idFromName: () => ({}),
  get: () => ({}),
} as unknown as Bindings["CALLBACKS"];

function makeIntegrations(db: Kysely<DB>, twistInstanceId: string): Integrations {
  return new Integrations({
    store: {} as never,
    env: { CALLBACKS: callbacksStub } as unknown as Bindings,
    ctx: { exports: {} } as never,
    db,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "personal",
    path: [],
  });
}

describeDb("Integrations.saveCustomEmoji", () => {
  let db: Kysely<DB>;

  beforeEach(() => {
    db = createDb({ DATABASE_URL } as unknown as Bindings);
  });

  afterEach(async () => {
    await db.destroy();
  });

  it("upserts emoji, resolves aliases, is idempotent, archives, and stamps scope", async () => {
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);

        // Seed a minimal twist + twist_instance (FK triggers disabled via
        // session_replication_role = replica).
        const twistPackageId = randomUUID();
        const userId = randomUUID();
        const twist = await trx
          .insertInto("twist")
          .values({
            twist_package_id: twistPackageId,
            environment: "personal",
            user_id: userId,
            name: "Custom Emoji Test Connector",
            handle: "custom-emoji-test",
            version: Date.now().toString(),
          })
          .returning("id")
          .executeTakeFirstOrThrow();
        const inst = await trx
          .insertInto("twist_instance")
          .values({
            twist_id: twist.id,
            owner_id: userId,
            name: "Custom Emoji Test Instance",
          })
          .returning("id")
          .executeTakeFirstOrThrow();
        const twistInstanceId = inst.id;

        const integrations = makeIntegrations(trx, twistInstanceId);

        const parrotInput = {
          id: "slack:T0/party_parrot",
          provider: "slack",
          workspace: "T0",
          name: "party_parrot",
          imageUrl:
            "https://emoji.slack-edge.com/T0/party_parrot/abc.gif",
          aliasOf: null,
          archived: false,
        };

        await integrations.saveCustomEmoji([
          parrotInput,
          {
            id: "slack:T0/pp_alias",
            provider: "slack",
            workspace: "T0",
            name: "pp_alias",
            imageUrl: null,
            aliasOf: "slack:T0/party_parrot",
            archived: false,
          },
        ]);

        let rows = await trx
          .selectFrom("custom_emoji")
          .selectAll()
          .where("workspace_id", "=", "T0")
          .execute();
        expect(rows).toHaveLength(2);
        const parrot = rows.find((r) => r.id === "slack:T0/party_parrot")!;
        expect(parrot.image_url).toContain("party_parrot");
        expect(parrot.archived_at).toBeNull();
        const alias = rows.find((r) => r.id === "slack:T0/pp_alias")!;
        expect(alias.alias_of).toBe("slack:T0/party_parrot");
        // Alias rows store empty image_url (renderer follows alias_of).
        expect(alias.image_url).toBe("");

        // Idempotent re-upsert updates image_url, doesn't duplicate.
        await integrations.saveCustomEmoji([
          { ...parrotInput, imageUrl: "https://emoji.slack-edge.com/T0/party_parrot/v2.gif" },
        ]);
        rows = await trx
          .selectFrom("custom_emoji")
          .selectAll()
          .where("workspace_id", "=", "T0")
          .execute();
        expect(rows).toHaveLength(2);
        const reparrot = rows.find((r) => r.id === "slack:T0/party_parrot")!;
        expect(reparrot.image_url).toContain("v2.gif");
        expect(reparrot.archived_at).toBeNull();

        // Archive.
        await integrations.saveCustomEmoji([{ ...parrotInput, archived: true }]);
        const archived = await trx
          .selectFrom("custom_emoji")
          .select("archived_at")
          .where("id", "=", "slack:T0/party_parrot")
          .executeTakeFirstOrThrow();
        expect(archived.archived_at).not.toBeNull();

        // Scope stamp.
        const stamped = await trx
          .selectFrom("twist_instance")
          .select("custom_emoji_scope")
          .where("id", "=", twistInstanceId)
          .executeTakeFirstOrThrow();
        expect(stamped.custom_emoji_scope).toBe("slack:T0");

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
  });

  it("no-ops on an empty emoji list", async () => {
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        const integrations = makeIntegrations(trx, randomUUID());
        await expect(integrations.saveCustomEmoji([])).resolves.toBeUndefined();
        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    }
  });
});
