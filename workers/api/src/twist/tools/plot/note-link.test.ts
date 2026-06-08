import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import { rpcUser } from "../../../rpc";
import { resolveOrCreateThreadBySource, createNoteScopedLink } from "./note";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/**
 * Seed a user with a linked primary identity and their root priority, run
 * `fn`, then roll the transaction back. Mirrors the harness in link.test.ts
 * but does NOT pre-create a thread — the find-or-create helper owns thread
 * creation.
 */
async function withUserRoot<T>(
  fn: (
    trx: Kysely<DB>,
    ctx: { userId: string; priorityRootId: string },
  ) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const email = `nl-${userId}@example.test`;
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
      captured = await fn(trx, { userId, priorityRootId });
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

describe.skipIf(!DATABASE_URL)("resolveOrCreateThreadBySource", () => {
  it("creates a bare thread when no link matches the source", async () => {
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const source = `granola:${randomUUID()}`;
      const threadId = await resolveOrCreateThreadBySource(
        trx,
        userId,
        priorityRootId,
        source,
        "Granola meeting notes",
      );

      const thread = await trx
        .selectFrom("thread")
        .select(["id", "title", "created_by"])
        .where("id", "=", threadId)
        .executeTakeFirst();

      const filing = await trx
        .selectFrom("thread_priority")
        .select(["thread_id", "user_id", "priority_id"])
        .where("thread_id", "=", threadId)
        .where("user_id", "=", userId)
        .executeTakeFirst();

      return { threadId, thread, filing, priorityRootId, userId };
    });

    // Returns a real uuid
    expect(result.threadId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    // A thread row now exists, non-null title, created_by = userId
    expect(result.thread).toBeDefined();
    expect(result.thread!.id).toBe(result.threadId);
    expect(result.thread!.title).toBe("Granola meeting notes");
    expect(result.thread!.created_by).toBe(result.userId);
    // A thread_priority filing now exists under the root priority
    expect(result.filing).toBeDefined();
    expect(result.filing!.priority_id).toBe(result.priorityRootId);
  });

  it("makes the created thread and a note on it visible to the owner via user views", async () => {
    // Regression: a raw INSERT INTO thread left thread.contacts = [], so the
    // anchor thread (and any note on it) was FILTERED OUT of user.thread /
    // user.note — invisible to its own owner. Creating via user.upsert_thread
    // appends the owner's primary contact and files thread_priority, fixing
    // visibility by construction. Assert through the user views, not raw rows.
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const source = `granola:${randomUUID()}`;
      const threadId = await resolveOrCreateThreadBySource(
        trx,
        userId,
        priorityRootId,
        source,
        "Granola meeting notes",
      );

      // Author a published note as the owner's primary linked contact.
      const primary = await sql<{ id: string }>`
        SELECT "user".user_contact_id(${userId}::uuid) AS id
      `.execute(trx);
      const authorId = primary.rows[0].id;

      const noteId = randomUUID();
      await sql`
        INSERT INTO note (id, thread_id, author_id, created_by, draft, content, source_created_at)
        VALUES (${noteId}::uuid, ${threadId}::uuid, ${authorId}::uuid, ${userId}::uuid, false, 'Anchor note body', now())
      `.execute(trx);

      // Anchor must stay canonical-link-free: twist_id and key NULL.
      const threadRow = await trx
        .selectFrom("thread")
        .select(["twist_id", "key", "contacts"])
        .where("id", "=", threadId)
        .executeTakeFirst();

      // Visibility via the user views.
      const threadVisible = await sql<{ c: number }>`
        SELECT count(*)::int AS c
        FROM "user".thread
        WHERE id = ${threadId}::uuid AND user_id = ${userId}::uuid
      `.execute(trx);
      const noteVisible = await sql<{ c: number }>`
        SELECT count(*)::int AS c
        FROM "user".note
        WHERE id = ${noteId}::uuid AND user_id = ${userId}::uuid
      `.execute(trx);

      return {
        threadRow,
        threadVisibleCount: Number(threadVisible.rows[0].c),
        noteVisibleCount: Number(noteVisible.rows[0].c),
      };
    });

    // Owner can see the thread and the note through the user views.
    expect(result.threadVisibleCount).toBe(1);
    expect(result.noteVisibleCount).toBe(1);
    // Anchor stays canonical-link-free so a later canonical createLink can
    // claim the thread-level slot.
    expect(result.threadRow).toBeDefined();
    expect(result.threadRow!.twist_id).toBeNull();
    expect(result.threadRow!.key).toBeNull();
    // Owner's primary contact is on the thread (the visibility-by-construction).
    expect(result.threadRow!.contacts!.length).toBeGreaterThan(0);
  });

  it("returns the existing thread when a link already matches the source", async () => {
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const threadId = await seedThread(trx, userId, priorityRootId);
      const source = `icaluid:${randomUUID()}`;

      // Seed an existing link on the thread carrying that source.
      await rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source, sources: [source] },
        p_defaults: { thread_id: threadId, created_by: userId },
      });

      const threadCountBefore = await trx
        .selectFrom("thread")
        .select(trx.fn.countAll<number>().as("c"))
        .executeTakeFirst();

      const resolved = await resolveOrCreateThreadBySource(
        trx,
        userId,
        priorityRootId,
        source,
        "fallback title",
      );

      const threadCountAfter = await trx
        .selectFrom("thread")
        .select(trx.fn.countAll<number>().as("c"))
        .executeTakeFirst();

      return {
        threadId,
        resolved,
        before: Number(threadCountBefore!.c),
        after: Number(threadCountAfter!.c),
      };
    });

    // Resolves to the existing thread, no new thread created.
    expect(result.resolved).toBe(result.threadId);
    expect(result.after).toBe(result.before);
  });

  it("finds a note-scoped link's thread (note_scoped participates)", async () => {
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const threadId = await seedThread(trx, userId, priorityRootId);
      const source = `granola:${randomUUID()}`;

      // The seed link is itself note-scoped — it must still be found.
      await rpcUser(trx, "upsert_link", {
        user_id: userId,
        p_link: { source, sources: [source] },
        p_defaults: { thread_id: threadId, created_by: userId, note_scoped: true },
      });

      const resolved = await resolveOrCreateThreadBySource(
        trx,
        userId,
        priorityRootId,
        source,
        "fallback title",
      );
      return { threadId, resolved };
    });

    expect(result.resolved).toBe(result.threadId);
  });
});

describe.skipIf(!DATABASE_URL)("createNoteScopedLink", () => {
  it("creates a note_scoped=true link on the given thread and returns its id", async () => {
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const threadId = await seedThread(trx, userId, priorityRootId);
      const source = `granola:${randomUUID()}`;

      const linkId = await createNoteScopedLink(trx, userId, threadId, {
        source,
        sources: [source],
        type: "granola-notes",
        title: "Granola notes",
        sourceUrl: "https://granola.example/abc",
      });

      const link = await trx
        .selectFrom("link")
        .select([
          "id",
          "thread_id",
          "note_scoped",
          "source",
          "type",
          "source_url",
          "created_by",
        ])
        .where("id", "=", linkId)
        .executeTakeFirst();

      return { linkId, threadId, userId, link };
    });

    expect(result.link).toBeDefined();
    expect(result.link!.id).toBe(result.linkId);
    expect(result.link!.thread_id).toBe(result.threadId);
    expect(result.link!.note_scoped).toBe(true);
    expect(result.link!.type).toBe("granola-notes");
    expect(result.link!.source_url).toBe("https://granola.example/abc");
    // created_by falls back to the user when no twist instance.
    expect(result.link!.created_by).toBe(result.userId);
  });

  it("creates a note_scoped link with no source via plain insert", async () => {
    const result = await withUserRoot(async (trx, { userId, priorityRootId }) => {
      const threadId = await seedThread(trx, userId, priorityRootId);

      const linkId = await createNoteScopedLink(trx, userId, threadId, {
        title: "Sourceless attachment",
        type: "doc",
      });

      const link = await trx
        .selectFrom("link")
        .select(["id", "thread_id", "note_scoped", "source", "type"])
        .where("id", "=", linkId)
        .executeTakeFirst();

      return { linkId, threadId, link };
    });

    expect(result.link).toBeDefined();
    expect(result.link!.id).toBe(result.linkId);
    expect(result.link!.thread_id).toBe(result.threadId);
    expect(result.link!.note_scoped).toBe(true);
    expect(result.link!.source).toBeNull();
    expect(result.link!.type).toBe("doc");
  });
});
