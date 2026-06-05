import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { selectDigestThreads } from "./email-digest-query";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type SeededNote = {
  /** author_id: defaults to a fresh random contact (i.e. someone else). */
  authorId?: string;
  /** When true, author_id = the recipient's OWN contact (overrides authorId). */
  bySelf?: boolean;
  /** null = Plot-authored; non-null = connector-synced (a bogus uuid is fine). */
  linkId: string | null;
  archived?: boolean;
};

type SeedOpts = {
  twistId: number | null; // null = Plot thread; non-null = connector thread
  notes: SeededNote[];
  importance?: number; // default 80
  readAt?: string | null; // default null (unread)
};

/**
 * Seed one user with one linked primary contact, one priority, one thread filed
 * for that user, its notes, and an unread thread_state — all with triggers
 * disabled for determinism — then run selectDigestThreads and roll back.
 * Returns { threadId, rows }.
 */
async function seedAndSelect(opts: SeedOpts) {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const contactId = randomUUID(); // the user's own contact
  const priorityId = randomUUID();
  const threadId = randomUUID();
  const email = `digest-${userId}@example.test`;

  let captured: Awaited<ReturnType<typeof selectDigestThreads>> = [];
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);

      await sql`INSERT INTO "user" (id, email) VALUES (${userId}::uuid, ${email})`.execute(trx);
      await sql`INSERT INTO contact (id, user_id, "primary", email)
        VALUES (${contactId}::uuid, ${userId}::uuid, true, ${email})`.execute(trx);
      await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary")
        VALUES (${userId}::uuid, ${contactId}::uuid, true, true)`.execute(trx);
      await sql`INSERT INTO priority (id, created_by, user_id, title, path)
        VALUES (${priorityId}::uuid, ${userId}::uuid, ${userId}::uuid, 'Inbox', 'inbox'::ltree)`.execute(trx);
      await sql`INSERT INTO thread (id, created_by, title, contacts, twist_id)
        VALUES (${threadId}::uuid, ${userId}::uuid, 'Test thread', ARRAY[${contactId}::uuid]::uuid[], ${opts.twistId})`.execute(trx);
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid)`.execute(trx);

      for (const n of opts.notes) {
        const author = n.bySelf ? contactId : n.authorId ?? randomUUID();
        await sql`INSERT INTO note (id, thread_id, author_id, created_by, link_id, archived_at)
          VALUES (${randomUUID()}::uuid, ${threadId}::uuid, ${author}::uuid, ${userId}::uuid,
                  ${n.linkId}, ${n.archived ? sql`now()` : null})`.execute(trx);
      }

      await sql`INSERT INTO thread_state (user_id, thread_id, read_at, importance)
        VALUES (${userId}::uuid, ${threadId}::uuid, ${opts.readAt ?? null}, ${opts.importance ?? 80})`.execute(trx);

      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      captured = await selectDigestThreads(trx, userId);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }

  return { threadId, rows: captured };
}

describe.skipIf(!DATABASE_URL)("selectDigestThreads", () => {
  it("includes a Plot thread with another person's Plot note", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ authorId: randomUUID(), linkId: null }], // other person, Plot-authored
    });
    expect(rows.map((r) => r.thread_id)).toContain(threadId);
  });

  it("excludes a connector-synced thread (twist_id set)", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: 1,
      notes: [{ authorId: randomUUID(), linkId: null }],
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });

  it("excludes a Plot thread whose only note is connector-synced (link_id set)", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ authorId: randomUUID(), linkId: randomUUID() }], // connector-synced note
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });

  it("excludes a Plot thread whose only Plot note was authored by the recipient", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ bySelf: true, linkId: null }],
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });

  it("excludes a Plot thread that has already been read", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ authorId: randomUUID(), linkId: null }],
      readAt: new Date().toISOString(),
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });

  it("includes a Plot thread that has both a self note and another person's Plot note", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [
        { bySelf: true, linkId: null },
        { authorId: randomUUID(), linkId: null },
      ],
    });
    expect(rows.map((r) => r.thread_id)).toContain(threadId);
  });

  it("excludes a low-importance, non-urgent Plot thread", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ authorId: randomUUID(), linkId: null }],
      importance: 10,
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });

  it("excludes a Plot thread whose only Plot note is archived", async () => {
    const { threadId, rows } = await seedAndSelect({
      twistId: null,
      notes: [{ authorId: randomUUID(), linkId: null, archived: true }],
    });
    expect(rows.map((r) => r.thread_id)).not.toContain(threadId);
  });
});
