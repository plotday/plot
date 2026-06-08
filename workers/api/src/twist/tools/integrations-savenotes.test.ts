import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { Integrations } from "./integrations";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/**
 * Seed a user + their root priority, run `fn`, then roll back. Mirrors the
 * harness in plot/note-link.test.ts but additionally seeds a `twist_instance`
 * (and the personal `twist` it references) so child rows can be `created_by`
 * the connector instance — which is what `archiveNotes` keys off of.
 */
async function withConnector<T>(
  fn: (
    trx: Kysely<DB>,
    ctx: {
      userId: string;
      priorityRootId: string;
      twistInstanceId: string;
    },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `sn-${userId}@example.test`;
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(
        trx,
      );
      await sql`SELECT public.upsert_user_contact(${userId}::uuid, ${email}, 'Owner', NULL)`.execute(
        trx,
      );
      const root = await sql<{ id: string }>`
        SELECT id FROM priority WHERE user_id = ${userId}::uuid ORDER BY path LIMIT 1
      `.execute(trx);
      const priorityRootId = root.rows[0].id;

      // A personal twist (user_id set, publisher_id null) + an instance owned
      // by the user. twist.id is identity (bigint); capture the generated id.
      const twistPackageId = randomUUID();
      const twist = await sql<{ id: string }>`
        INSERT INTO twist (environment, name, version, twist_package_id, handle, user_id)
        VALUES ('personal', 'Test Augmenter', '0.0.0', ${twistPackageId}::uuid, 'test-augmenter', ${userId}::uuid)
        RETURNING id
      `.execute(trx);
      const twistId = twist.rows[0].id;

      const twistInstanceId = randomUUID();
      await sql`
        INSERT INTO twist_instance (id, twist_id, owner_id, name)
        VALUES (${twistInstanceId}::uuid, ${twistId}, ${userId}::uuid, 'Test Augmenter')
      `.execute(trx);

      captured = await fn(trx, { userId, priorityRootId, twistInstanceId });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

/** Seed a thread filed under the user's root priority. */
async function seedThread(
  trx: Kysely<DB>,
  userId: string,
  priorityRootId: string,
): Promise<string> {
  const threadId = randomUUID();
  await sql`INSERT INTO thread (id, created_by, title) VALUES (${threadId}::uuid, ${userId}::uuid, 'Seeded thread')`.execute(
    trx,
  );
  await sql`
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityRootId}::uuid)
  `.execute(trx);
  return threadId;
}

/** Seed a note_scoped link created_by the connector instance, on a channel. */
async function seedNoteScopedLink(
  trx: Kysely<DB>,
  threadId: string,
  twistInstanceId: string,
  channelId: string | null,
): Promise<string> {
  const linkId = randomUUID();
  await sql`
    INSERT INTO link (id, thread_id, created_by, channel_id, note_scoped, type)
    VALUES (${linkId}::uuid, ${threadId}::uuid, ${twistInstanceId}::uuid, ${channelId}, true, 'granola-notes')
  `.execute(trx);
  return linkId;
}

/** Seed a note created_by the connector instance, attached to a link. */
async function seedConnectorNote(
  trx: Kysely<DB>,
  threadId: string,
  twistInstanceId: string,
  linkId: string | null,
): Promise<string> {
  const noteId = randomUUID();
  await sql`
    INSERT INTO note (id, thread_id, author_id, created_by, link_id, draft, content, source_created_at)
    VALUES (${noteId}::uuid, ${threadId}::uuid, ${twistInstanceId}::uuid, ${twistInstanceId}::uuid, ${linkId}, false, 'Augmenter note body', now())
  `.execute(trx);
  return noteId;
}

/**
 * Construct a real Integrations tool bound to the rollback transaction (db =
 * trx) and call its REAL `archiveNotes`. `twistInstanceId` must equal the
 * seeded connector instance whose `created_by` rows we archive. The constructor
 * only assigns fields + synthesizes a CALLBACKS DO stub; we override getPlot so
 * notifySyncDOs is a no-op (it would otherwise reach a Durable Object namespace
 * unavailable under vitest). This proves the load-bearing archival semantics —
 * both the note-attached link and the note get archived_at set, scoped by
 * channel — through the actual production method rather than a SQL replica.
 *
 * `archiveNotes` operates on `this.db` directly (no inner transaction), so it
 * nests cleanly inside the harness's rollback transaction.
 */
async function runArchiveNotes(
  trx: Kysely<DB>,
  twistInstanceId: string,
  channelId?: string,
): Promise<void> {
  const env = {
    CALLBACKS: {
      idFromName: () => ({ name: "stub" }),
      get: () => ({}),
    },
  } as unknown as Bindings;

  const integrations = new Integrations({
    store: {} as never,
    env,
    ctx: { exports: {} as never },
    db: trx,
    twistInstanceId,
    twistId: randomUUID(),
    environment: "development" as never,
    path: [],
  });

  (integrations as unknown as { getPlot: () => unknown }).getPlot = () => ({
    notifySyncDOs: async () => {},
  });

  await integrations.archiveNotes(
    channelId !== undefined ? { channelId } : {},
  );
}

async function isArchived(
  trx: Kysely<DB>,
  table: "note" | "link",
  id: string,
): Promise<boolean> {
  const row = await sql<{ archived_at: string | null }>`
    SELECT archived_at FROM public.${sql.raw(table)} WHERE id = ${id}::uuid
  `.execute(trx);
  return row.rows[0].archived_at !== null;
}

describe.skipIf(!DATABASE_URL)("archiveNotes archival semantics", () => {
  it("archives both the note and its note-scoped link (no channel filter)", async () => {
    const result = await withConnector(
      async (trx, { userId, priorityRootId, twistInstanceId }) => {
        const threadId = await seedThread(trx, userId, priorityRootId);
        const linkId = await seedNoteScopedLink(
          trx,
          threadId,
          twistInstanceId,
          "channel-A",
        );
        const noteId = await seedConnectorNote(
          trx,
          threadId,
          twistInstanceId,
          linkId,
        );

        await runArchiveNotes(trx, twistInstanceId);

        return {
          noteArchived: await isArchived(trx, "note", noteId),
          linkArchived: await isArchived(trx, "link", linkId),
        };
      },
    );

    expect(result.noteArchived).toBe(true);
    expect(result.linkArchived).toBe(true);
  });

  it("scopes archival to the given channel, leaving other channels' notes/links intact", async () => {
    const result = await withConnector(
      async (trx, { userId, priorityRootId, twistInstanceId }) => {
        const threadId = await seedThread(trx, userId, priorityRootId);

        // Channel A — should be archived.
        const linkA = await seedNoteScopedLink(
          trx,
          threadId,
          twistInstanceId,
          "channel-A",
        );
        const noteA = await seedConnectorNote(
          trx,
          threadId,
          twistInstanceId,
          linkA,
        );

        // Channel B — should be left intact.
        const linkB = await seedNoteScopedLink(
          trx,
          threadId,
          twistInstanceId,
          "channel-B",
        );
        const noteB = await seedConnectorNote(
          trx,
          threadId,
          twistInstanceId,
          linkB,
        );

        await runArchiveNotes(trx, twistInstanceId, "channel-A");

        return {
          noteAArchived: await isArchived(trx, "note", noteA),
          linkAArchived: await isArchived(trx, "link", linkA),
          noteBArchived: await isArchived(trx, "note", noteB),
          linkBArchived: await isArchived(trx, "link", linkB),
        };
      },
    );

    // Channel A archived.
    expect(result.noteAArchived).toBe(true);
    expect(result.linkAArchived).toBe(true);
    // Channel B untouched.
    expect(result.noteBArchived).toBe(false);
    expect(result.linkBArchived).toBe(false);
  });

  it("does not touch notes/links created by a different connector", async () => {
    const result = await withConnector(
      async (trx, { userId, priorityRootId, twistInstanceId }) => {
        const threadId = await seedThread(trx, userId, priorityRootId);

        // A note + link created by SOME OTHER actor (the user, here) must not
        // be archived — archiveNotes is scoped by created_by = this connector.
        const otherLink = await seedNoteScopedLink(
          trx,
          threadId,
          userId,
          "channel-A",
        );
        const otherNote = await seedConnectorNote(
          trx,
          threadId,
          userId,
          otherLink,
        );

        // This connector's own note + link, same channel.
        const ownLink = await seedNoteScopedLink(
          trx,
          threadId,
          twistInstanceId,
          "channel-A",
        );
        const ownNote = await seedConnectorNote(
          trx,
          threadId,
          twistInstanceId,
          ownLink,
        );

        await runArchiveNotes(trx, twistInstanceId, "channel-A");

        return {
          ownNoteArchived: await isArchived(trx, "note", ownNote),
          ownLinkArchived: await isArchived(trx, "link", ownLink),
          otherNoteArchived: await isArchived(trx, "note", otherNote),
          otherLinkArchived: await isArchived(trx, "link", otherLink),
        };
      },
    );

    expect(result.ownNoteArchived).toBe(true);
    expect(result.ownLinkArchived).toBe(true);
    expect(result.otherNoteArchived).toBe(false);
    expect(result.otherLinkArchived).toBe(false);
  });
});
