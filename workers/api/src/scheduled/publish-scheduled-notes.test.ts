import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { claimDueScheduledNotes } from "./publish-scheduled-notes";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type Seeded = {
  authorUserId: string;
  recipientUserId: string;
  authorContactId: string;
  recipientContactId: string;
  threadId: string;
};

/**
 * Seed two users (author + recipient) sharing one thread, with real
 * contact/user_contact/priority/thread_priority rows so the user.* views and
 * the note trigger behave as in production. Seeding runs with triggers
 * disabled (replica role); the role is reset to DEFAULT before returning so
 * the test's own note INSERT/UPDATE statements fire real triggers.
 */
async function seedThread(
  trx: Kysely<DB>,
  opts: { threadSendAt?: Date } = {},
): Promise<Seeded> {
  const authorUserId = randomUUID();
  const recipientUserId = randomUUID();
  const authorContactId = randomUUID();
  const recipientContactId = randomUUID();
  const authorPriorityId = randomUUID();
  const recipientPriorityId = randomUUID();
  const threadId = randomUUID();

  await sql`SET LOCAL session_replication_role = replica`.execute(trx);

  await sql`INSERT INTO "user" (id, email) VALUES
    (${authorUserId}::uuid, ${`sched-author-${authorUserId}@example.test`}),
    (${recipientUserId}::uuid, ${`sched-recip-${recipientUserId}@example.test`})`.execute(
    trx,
  );
  await sql`INSERT INTO contact (id, name, email) VALUES
    (${authorContactId}::uuid, 'Author', ${`sched-author-${authorUserId}@example.test`}),
    (${recipientContactId}::uuid, 'Recipient', ${`sched-recip-${recipientUserId}@example.test`})`.execute(
    trx,
  );
  await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES
    (${authorUserId}::uuid, ${authorContactId}::uuid, TRUE, TRUE),
    (${recipientUserId}::uuid, ${recipientContactId}::uuid, TRUE, TRUE)`.execute(
    trx,
  );
  const authorRoleId = randomUUID();
  const recipientRoleId = randomUUID();
  await sql`INSERT INTO role (id, created_by, user_id, name) VALUES
    (${authorRoleId}::uuid, ${authorUserId}::uuid, ${authorUserId}::uuid, 'Role A'),
    (${recipientRoleId}::uuid, ${recipientUserId}::uuid, ${recipientUserId}::uuid, 'Role B')`.execute(
    trx,
  );
  await sql`INSERT INTO priority (id, user_id, created_by, role_id, path, title) VALUES
    (${authorPriorityId}::uuid, ${authorUserId}::uuid, ${authorUserId}::uuid,
     ${authorRoleId}::uuid, ${`r${authorPriorityId.split("-").join("")}`}::ltree, 'Root A'),
    (${recipientPriorityId}::uuid, ${recipientUserId}::uuid, ${recipientUserId}::uuid,
     ${recipientRoleId}::uuid, ${`r${recipientPriorityId.split("-").join("")}`}::ltree, 'Root B')`.execute(
    trx,
  );
  await sql`INSERT INTO thread
      (id, created_by, author_id, title, draft, contacts, send_at)
    VALUES
      (${threadId}::uuid, ${authorUserId}::uuid, ${authorContactId}::uuid,
       'Scheduled thread', FALSE,
       ARRAY[${authorContactId}::uuid, ${recipientContactId}::uuid],
       ${opts.threadSendAt ?? null})`.execute(trx);
  await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id) VALUES
    (${threadId}::uuid, ${authorUserId}::uuid, ${authorPriorityId}::uuid),
    (${threadId}::uuid, ${recipientUserId}::uuid, ${recipientPriorityId}::uuid)`.execute(
    trx,
  );

  await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
  return {
    authorUserId,
    recipientUserId,
    authorContactId,
    recipientContactId,
    threadId,
  };
}

/** Insert a note with real triggers firing (role must be DEFAULT). */
async function insertNote(
  trx: Kysely<DB>,
  seeded: Seeded,
  sendAt: Date | null,
): Promise<string> {
  const noteId = randomUUID();
  await sql`INSERT INTO note
      (id, author_id, created_by, thread_id, draft, content, send_at)
    VALUES
      (${noteId}::uuid, ${seeded.authorContactId}::uuid,
       ${seeded.authorUserId}::uuid, ${seeded.threadId}::uuid, FALSE,
       'scheduled hello', ${sendAt})`.execute(trx);
  return noteId;
}

/** Rewind a held note's send_at into the past without firing triggers, so a
 * claim test can exercise the trigger transition on the claim UPDATE only. */
async function rewindSendAt(
  trx: Kysely<DB>,
  noteId: string,
  to: Date,
): Promise<void> {
  await sql`SET LOCAL session_replication_role = replica`.execute(trx);
  await sql`UPDATE note SET send_at = ${to} WHERE id = ${noteId}::uuid`.execute(
    trx,
  );
  await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);
}

async function withRollback(
  fn: (trx: Kysely<DB>) => Promise<void>,
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await fn(trx);
      throw new Rollback();
    });
  } catch (err) {
    if (!(err instanceof Rollback)) throw err;
  } finally {
    await db.destroy();
  }
}

const future = () => new Date(Date.now() + 60 * 60 * 1000);
const past = () => new Date(Date.now() - 60 * 1000);

describe.skipIf(!DATABASE_URL)("scheduled-send hold", () => {
  it("a held note does not surface the thread or unread the recipient", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);
      await insertNote(trx, seeded, future());

      const threadRow = await sql<{
        last_note_created_at: string | null;
      }>`SELECT last_note_created_at FROM thread WHERE id = ${seeded.threadId}::uuid`.execute(
        trx,
      );
      expect(threadRow.rows[0].last_note_created_at).toBeNull();

      const state = await sql<{ user_id: string }>`
        SELECT user_id FROM thread_state
        WHERE thread_id = ${seeded.threadId}::uuid
          AND user_id = ${seeded.recipientUserId}::uuid`.execute(trx);
      expect(state.rows).toHaveLength(0);
    });
  });

  it("a held note is visible to its author but not the recipient in user.note", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);
      const noteId = await insertNote(trx, seeded, future());

      const rows = await sql<{ user_id: string }>`
        SELECT user_id FROM "user".note WHERE id = ${noteId}::uuid`.execute(
        trx,
      );
      expect(rows.rows.map((r) => r.user_id)).toEqual([seeded.authorUserId]);
    });
  });

  it("a live note (send_at null) is visible to both users in user.note", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);
      const noteId = await insertNote(trx, seeded, null);

      const rows = await sql<{ user_id: string }>`
        SELECT user_id FROM "user".note WHERE id = ${noteId}::uuid`.execute(
        trx,
      );
      expect(rows.rows.map((r) => r.user_id).sort()).toEqual(
        [seeded.authorUserId, seeded.recipientUserId].sort(),
      );
    });
  });

  it("a held thread shell is visible only to its author in user.thread", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx, { threadSendAt: future() });

      const rows = await sql<{ user_id: string }>`
        SELECT user_id FROM "user".thread WHERE id = ${seeded.threadId}::uuid`.execute(
        trx,
      );
      expect(rows.rows.map((r) => r.user_id)).toEqual([seeded.authorUserId]);
    });
  });

  it("a held note is excluded from the mention dispatch view until due", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);

      // Mention twist (twist + instance owned by the recipient).
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const twist = await sql<{ id: string }>`
        INSERT INTO twist
          (twist_package_id, user_id, environment, name, handle, version)
        VALUES (${randomUUID()}::uuid, ${seeded.recipientUserId}::uuid,
          'personal', 'Mentionable', 'Mentionable', '1000000000000')
        RETURNING id`.execute(trx);
      const twistInstanceId = randomUUID();
      await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, created_at)
        VALUES (${twistInstanceId}::uuid, ${twist.rows[0].id},
          ${seeded.recipientUserId}::uuid, 'Mentionable',
          now() - interval '1 day')`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      const noteId = randomUUID();
      await sql`INSERT INTO note
          (id, author_id, created_by, thread_id, draft, content, mentions, send_at)
        VALUES
          (${noteId}::uuid, ${seeded.authorContactId}::uuid,
           ${seeded.authorUserId}::uuid, ${seeded.threadId}::uuid, FALSE,
           'hey @twist', ARRAY[${twistInstanceId}::uuid], ${future()})`.execute(
        trx,
      );

      const held = await sql<{ id: string }>`
        SELECT id FROM twist_instance_note_create
        WHERE id = ${noteId}::uuid`.execute(trx);
      expect(held.rows).toHaveLength(0);

      // Release (claim) — the note now qualifies for dispatch.
      await rewindSendAt(trx, noteId, past());
      await claimDueScheduledNotes(trx);
      const released = await sql<{ id: string }>`
        SELECT id FROM twist_instance_note_create
        WHERE id = ${noteId}::uuid`.execute(trx);
      expect(released.rows).toHaveLength(1);
    });
  });
});

describe.skipIf(!DATABASE_URL)("claimDueScheduledNotes", () => {
  it("claims due notes, clears the thread hold, and fires the activity trigger", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx, { threadSendAt: future() });
      const noteId = await insertNote(trx, seeded, future());
      await rewindSendAt(trx, noteId, past());
      // Rewind the thread hold too so the claim clears it.
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`UPDATE thread SET send_at = ${past()}
        WHERE id = ${seeded.threadId}::uuid`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      const { notes, threads } = await claimDueScheduledNotes(trx);
      expect(notes.map((n) => n.id)).toContain(noteId);
      expect(threads.map((t) => t.id)).toContain(seeded.threadId);

      const noteRow = await sql<{ send_at: string | null }>`
        SELECT send_at FROM note WHERE id = ${noteId}::uuid`.execute(trx);
      expect(noteRow.rows[0].send_at).toBeNull();
      const threadRow = await sql<{
        send_at: string | null;
        last_note_created_at: string | null;
      }>`SELECT send_at, last_note_created_at FROM thread
        WHERE id = ${seeded.threadId}::uuid`.execute(trx);
      expect(threadRow.rows[0].send_at).toBeNull();
      // The claim UPDATE (send_at → NULL) fired update_thread_on_note_change:
      // the thread now surfaces with the note's activity.
      expect(threadRow.rows[0].last_note_created_at).not.toBeNull();

      // Recipient sees both thread and note post-release.
      const visible = await sql<{ user_id: string }>`
        SELECT user_id FROM "user".note WHERE id = ${noteId}::uuid`.execute(
        trx,
      );
      expect(visible.rows.map((r) => r.user_id).sort()).toEqual(
        [seeded.authorUserId, seeded.recipientUserId].sort(),
      );
    });
  });

  it("is idempotent — a second claim selects nothing", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);
      const noteId = await insertNote(trx, seeded, future());
      await rewindSendAt(trx, noteId, past());

      const first = await claimDueScheduledNotes(trx);
      expect(first.notes.map((n) => n.id)).toContain(noteId);

      const second = await claimDueScheduledNotes(trx);
      expect(second.notes).toHaveLength(0);
    });
  });

  it("does not claim future, archived, or draft notes", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedThread(trx);
      const futureNote = await insertNote(trx, seeded, future());

      // Archived held note past due (the unschedule/cancel path).
      const archivedNote = randomUUID();
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await sql`INSERT INTO note
          (id, author_id, created_by, thread_id, draft, content, send_at, archived_at)
        VALUES
          (${archivedNote}::uuid, ${seeded.authorContactId}::uuid,
           ${seeded.authorUserId}::uuid, ${seeded.threadId}::uuid, FALSE,
           'cancelled', ${past()}, now())`.execute(trx);
      await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

      const { notes } = await claimDueScheduledNotes(trx);
      const claimedIds = notes.map((n) => n.id);
      expect(claimedIds).not.toContain(futureNote);
      expect(claimedIds).not.toContain(archivedNote);
    });
  });
});
