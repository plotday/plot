import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, it, expect } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  blockquote,
  buildFallbackContent,
  buildSnapshotAction,
  resolveForwardSource,
} from "./forward";

describe("blockquote", () => {
  it("prefixes every line with '> '", () => {
    expect(blockquote("line 1\nline 2")).toBe("> line 1\n> line 2");
  });
  it("keeps blank lines quoted so the block stays contiguous", () => {
    expect(blockquote("a\n\nb")).toBe("> a\n>\n> b");
  });
  it("returns empty string for empty input", () => {
    expect(blockquote("")).toBe("");
  });
});

describe("buildFallbackContent", () => {
  const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
  it("puts the user's message above the quoted original with an attribution line", () => {
    expect(buildFallbackContent("FYI", snap)).toBe(
      "FYI\n\n---\n\nForwarded from Alice — Q3\n\n> hi",
    );
  });
  it("omits the leading blank when the user wrote nothing", () => {
    expect(buildFallbackContent("", snap)).toBe("---\n\nForwarded from Alice — Q3\n\n> hi");
  });
  it("drops the 'from {name}' clause when sourceAuthorName is empty (twist-authored source)", () => {
    const noAuthorSnap = { ...snap, sourceAuthorName: "" };
    expect(buildFallbackContent("FYI", noAuthorSnap)).toBe(
      "FYI\n\n---\n\nForwarded — Q3\n\n> hi",
    );
  });
});

describe("buildSnapshotAction", () => {
  it("emits ForwardUserAction JSON matching the Flutter shape", () => {
    const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
    expect(buildSnapshotAction(snap)).toEqual({
      type: "forward",
      sourceTitle: "Q3",
      sourceAuthorName: "Alice",
      quotedContent: "> hi",
      sourceThreadId: "t1",
    });
  });
});

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

type Seeded = {
  authorUserId: string;
  otherUserId: string;
  authorContactId: string;
  otherContactId: string;
  threadId: string;
  noteId: string;
};

/**
 * Seed a thread that only `authorUserId` can see (thread.contacts contains
 * only the author's contact — `otherUserId`'s contact is never added), with
 * one note on it. Mirrors the two-user seeding pattern in
 * publish-scheduled-notes.test.ts, but deliberately withholds the second
 * user from thread.contacts so no thread_priority row is ever filed for
 * them — the exact real-world shape of the IDOR: an attacker with no
 * relationship whatsoever to the thread supplies its note id directly (as
 * the client-controlled `fwd_note` / `note_fwd_note` body fields).
 */
async function seedPrivateThreadWithNote(trx: Kysely<DB>): Promise<Seeded> {
  const authorUserId = randomUUID();
  const otherUserId = randomUUID();
  const authorContactId = randomUUID();
  const otherContactId = randomUUID();
  const authorPriorityId = randomUUID();
  const otherPriorityId = randomUUID();
  const threadId = randomUUID();
  const noteId = randomUUID();

  await sql`SET LOCAL session_replication_role = replica`.execute(trx);

  await sql`INSERT INTO "user" (id, email) VALUES
    (${authorUserId}::uuid, ${`fwd-author-${authorUserId}@example.test`}),
    (${otherUserId}::uuid, ${`fwd-other-${otherUserId}@example.test`})`.execute(
    trx,
  );
  await sql`INSERT INTO contact (id, name, email) VALUES
    (${authorContactId}::uuid, 'Author', ${`fwd-author-${authorUserId}@example.test`}),
    (${otherContactId}::uuid, 'Other', ${`fwd-other-${otherUserId}@example.test`})`.execute(
    trx,
  );
  await sql`INSERT INTO user_contact (user_id, contact_id, linked, "primary") VALUES
    (${authorUserId}::uuid, ${authorContactId}::uuid, TRUE, TRUE),
    (${otherUserId}::uuid, ${otherContactId}::uuid, TRUE, TRUE)`.execute(trx);
  const authorRoleId = randomUUID();
  const otherRoleId = randomUUID();
  await sql`INSERT INTO role (id, created_by, user_id, name) VALUES
    (${authorRoleId}::uuid, ${authorUserId}::uuid, ${authorUserId}::uuid, 'Role A'),
    (${otherRoleId}::uuid, ${otherUserId}::uuid, ${otherUserId}::uuid, 'Role B')`.execute(
    trx,
  );
  await sql`INSERT INTO priority (id, user_id, created_by, role_id, path, title) VALUES
    (${authorPriorityId}::uuid, ${authorUserId}::uuid, ${authorUserId}::uuid,
     ${authorRoleId}::uuid, ${`r${authorPriorityId.split("-").join("")}`}::ltree, 'Root A'),
    (${otherPriorityId}::uuid, ${otherUserId}::uuid, ${otherUserId}::uuid,
     ${otherRoleId}::uuid, ${`r${otherPriorityId.split("-").join("")}`}::ltree, 'Root B')`.execute(
    trx,
  );

  // thread.contacts intentionally omits otherContactId — the "other" user
  // has zero relationship to this thread. This is what makes attempting to
  // read the note by id (with no authorization) an IDOR: nothing about
  // otherUserId's own data ever points at this thread or note.
  await sql`INSERT INTO thread
      (id, created_by, author_id, title, draft, contacts)
    VALUES
      (${threadId}::uuid, ${authorUserId}::uuid, ${authorContactId}::uuid,
       'Private thread', FALSE, ARRAY[${authorContactId}::uuid])`.execute(trx);
  await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id) VALUES
    (${threadId}::uuid, ${authorUserId}::uuid, ${authorPriorityId}::uuid)`.execute(
    trx,
  );

  await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

  // Insert with real triggers firing (role is DEFAULT again).
  await sql`INSERT INTO note
      (id, author_id, created_by, thread_id, draft, content)
    VALUES
      (${noteId}::uuid, ${authorContactId}::uuid, ${authorUserId}::uuid,
       ${threadId}::uuid, FALSE, 'Secret note only the author can see')`.execute(
    trx,
  );

  return {
    authorUserId,
    otherUserId,
    authorContactId,
    otherContactId,
    threadId,
    noteId,
  };
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

describe.skipIf(!DATABASE_URL)("resolveForwardSource authorization (IDOR)", () => {
  it("returns null when the requesting user cannot see the source note (cross-tenant)", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedPrivateThreadWithNote(trx);

      // Attacker: a user with no relationship to the thread/note, supplying
      // the victim's note id directly (as fwd_note / note_fwd_note would be
      // client-controlled in the real request bodies).
      const result = await resolveForwardSource(
        trx,
        seeded.otherUserId,
        seeded.noteId,
      );

      expect(result).toBeNull();
    });
  });

  it("returns the source snapshot when the requesting user is the note's author", async () => {
    await withRollback(async (trx) => {
      const seeded = await seedPrivateThreadWithNote(trx);

      const result = await resolveForwardSource(
        trx,
        seeded.authorUserId,
        seeded.noteId,
      );

      expect(result).not.toBeNull();
      expect(result?.snapshot.sourceThreadId).toBe(seeded.threadId);
      expect(result?.snapshot.quotedContent).toContain(
        "Secret note only the author can see",
      );
    });
  });
});
