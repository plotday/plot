# Email digest: only notify on unseen Plot-authored content — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The unseen-activity email digest must exclude connector-synced threads and only send when there is a genuine, unseen, Plot-authored note.

**Architecture:** The digest's thread-selection SQL currently lives inline in `EmailNotify.alarm()` (`workers/api/src/state/email-notify.ts`). Task 1 extracts it verbatim into a focused, node-importable module `email-digest-query.ts` exporting a typed `selectDigestThreads(db, userId)` — no behavior change. Task 2 adds, test-first, two `WHERE` clauses to that function: `thread.twist_id IS NULL` (exclude connector threads) and an `EXISTS` gate requiring a non-archived, Plot-authored (`note.link_id IS NULL`) note the user didn't author (`note.author_id` not in `user.user_contact_ids`). Task 3 finalizes (lint, docs).

**Tech Stack:** TypeScript, Cloudflare Workers Durable Objects, Kysely raw `sql`, PostgreSQL, Vitest (node-env unit config).

**Spec:** `docs/superpowers/specs/2026-06-05-email-notify-plot-only-threads-design.md`

---

## File Structure

- **Create** `workers/api/src/state/email-digest-query.ts` — the digest thread-selection query as one focused, testable unit. No `cloudflare:workers` import, so it is importable in the node-env unit test config. Exports `DigestThreadRow` and `selectDigestThreads(db, userId)`.
- **Create** `workers/api/src/state/email-digest-query.test.ts` — real-Postgres integration test for `selectDigestThreads`, guarded by `describe.skipIf(!process.env.DATABASE_URL)`, isolated per test by transaction rollback with triggers disabled during seeding.
- **Modify** `workers/api/src/state/email-notify.ts` — replace the inline query (lines ~133-164) with a call to `selectDigestThreads`; rename the local `threadsResult.rows` references to `rows`.
- **Modify** `docs/updates.md` — one user-facing bullet.

### Background facts locked in from the schema (do not re-derive)

- `thread.twist_id` is `bigint`, **no FK** ("FK intentionally omitted") — a connector thread can be seeded with `twist_id = 1` without a `twist` row.
- `note.link_id` references `link(id)` (a real FK) — seeding a connector note with a bogus `link_id` requires FK triggers disabled.
- `note.author_id` is a **contact** id (the user's contact for user-authored notes; the twist_instance id for twist notes). `note.created_by` is the actor (user_id or twist_instance_id).
- `"user".user_contact_ids(uuid)` returns `uuid[]` of the user's `user_contact` rows where `linked = TRUE AND archived_at IS NULL`. It is `STABLE`.
- Seeding uses `SET LOCAL session_replication_role = replica` to disable **all** user + FK triggers for deterministic inserts, then `SET LOCAL session_replication_role = DEFAULT` before running the query (a `SELECT`, unaffected by triggers). The local dev DB connects as superuser `postgres`, which is permitted to set this.
- Required-on-insert columns used below: `user(id, email)`; `contact(id, user_id, "primary", email)` (a `primary` contact requires `user_id`); `user_contact(user_id, contact_id, linked, "primary")`; `priority(id, created_by, user_id, title, path)` (`path` is `ltree`); `thread(id, created_by, title, contacts, twist_id)` (`title` required when not draft); `thread_priority(thread_id, user_id, priority_id)`; `note(id, thread_id, author_id, created_by, link_id, archived_at)`; `thread_state(user_id, thread_id, read_at, importance)`.

---

## Task 1: Extract the digest query into a focused module

**Files:**
- Create: `workers/api/src/state/email-digest-query.ts`
- Modify: `workers/api/src/state/email-notify.ts`

- [ ] **Step 1: Create the query module (behavior-preserving copy of the current SQL)**

Create `workers/api/src/state/email-digest-query.ts` with exactly:

```ts
import { sql, type Kysely } from "kysely";

import type { DB } from "../db";

/** One unread thread eligible for the email digest, with its filing priority. */
export type DigestThreadRow = {
  thread_id: string;
  thread_title: string | null;
  thread_preview: string | null;
  thread_updated_at: string;
  priority_id: string;
  priority_path: string;
  priority_title: string;
};

/**
 * Select the unread threads that should appear in a user's email digest,
 * newest first.
 *
 * Only genuine Plot activity qualifies:
 *   - connector-synced threads (`thread.twist_id IS NOT NULL`) are excluded, and
 *   - the thread must contain at least one non-archived note authored in Plot
 *     (`note.link_id IS NULL`) by someone other than the recipient
 *     (`note.author_id` not among the user's linked contacts).
 *
 * `db` may be a Kysely instance or a transaction handle (Transaction extends Kysely).
 */
export async function selectDigestThreads(
  db: Kysely<DB>,
  userId: string
): Promise<DigestThreadRow[]> {
  const result = await sql<DigestThreadRow>`
    SELECT
      t.id::text AS thread_id,
      t.title AS thread_title,
      t.preview AS thread_preview,
      tu.updated_at::text AS thread_updated_at,
      p.id::text AS priority_id,
      p.path::text AS priority_path,
      p.title AS priority_title
    FROM thread_state tu
    JOIN thread t ON t.id = tu.thread_id
    JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${userId}::uuid
    JOIN priority p ON p.id = tp.priority_id
    WHERE tu.user_id = ${userId}::uuid
      AND tu.read_at IS NULL
      AND (tu.importance >= 50 OR tu.urgent = TRUE)
      AND t.archived_at IS NULL
      AND (t.draft = false OR t.created_by = ${userId}::uuid)
      AND (
        t.contacts && "user".user_contact_ids(${userId}::uuid)
        OR t.groups && "user".user_group_ids(${userId}::uuid)
      )
    ORDER BY tu.updated_at DESC
  `.execute(db);
  return result.rows;
}
```

Note: this is the **current** behavior — the two new clauses are added in Task 2. The `DB` type and `sql` re-export both come from `../db` (`workers/api/src/db.ts` re-exports `type DB` and `sql`).

- [ ] **Step 2: Wire `email-notify.ts` to the new function**

In `workers/api/src/state/email-notify.ts`:

Add the import alongside the existing imports (after the `notification-summary` import block near line 12):

```ts
import { selectDigestThreads } from "./email-digest-query";
```

Replace the inline query block. The current code (lines ~133-164) is:

```ts
        const threadsResult = await sql<{
          thread_id: string;
          thread_title: string | null;
          thread_preview: string | null;
          thread_updated_at: string;
          priority_id: string;
          priority_path: string;
          priority_title: string;
        }>`
          SELECT
            t.id::text AS thread_id,
            t.title AS thread_title,
            t.preview AS thread_preview,
            tu.updated_at::text AS thread_updated_at,
            p.id::text AS priority_id,
            p.path::text AS priority_path,
            p.title AS priority_title
          FROM thread_state tu
          JOIN thread t ON t.id = tu.thread_id
          JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = ${this.userId!}::uuid
          JOIN priority p ON p.id = tp.priority_id
          WHERE tu.user_id = ${this.userId!}::uuid
            AND tu.read_at IS NULL
            AND (tu.importance >= 50 OR tu.urgent = TRUE)
            AND t.archived_at IS NULL
            AND (t.draft = false OR t.created_by = ${this.userId!}::uuid)
            AND (
              t.contacts && "user".user_contact_ids(${this.userId!}::uuid)
              OR t.groups && "user".user_group_ids(${this.userId!}::uuid)
            )
          ORDER BY tu.updated_at DESC
        `.execute(db);
```

Replace that entire statement with:

```ts
        const rows = await selectDigestThreads(db, this.userId!);
```

Then update the four references to `threadsResult.rows` that follow:
- `if (threadsResult.rows.length === 0) {` → `if (rows.length === 0) {`
- `const latestUpdatedAt = threadsResult.rows[0].thread_updated_at;` → `const latestUpdatedAt = rows[0].thread_updated_at;`
- `for (const row of threadsResult.rows) {` → `for (const row of rows) {`
- `thread_count: threadsResult.rows.length,` → `thread_count: rows.length,`

Leave the rest of `alarm()` (user lookup, settings, token upsert, first-level-path query, grouping, summaries, queue send) unchanged. The remaining `sql` template usages in the file keep the `import { sql } from "kysely";` import in place.

- [ ] **Step 3: Verify it compiles (no behavior change yet)**

Run: `cd workers/api && pnpm exec tsc`
Expected: no new `error TS` lines for `email-notify.ts` or `email-digest-query.ts`. (Per repo convention `main` already has 2 pre-existing `tsc` errors — `Uint8Array`/`BlobPart`; the gate is "no NEW errors", not exit 0.)

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/state/email-digest-query.ts workers/api/src/state/email-notify.ts
git commit -m "refactor(email-notify): extract digest thread query into selectDigestThreads

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Filter to unseen Plot-authored content (test-first)

**Files:**
- Create: `workers/api/src/state/email-digest-query.test.ts`
- Modify: `workers/api/src/state/email-digest-query.ts`

- [ ] **Step 1: Write the failing integration test**

Create `workers/api/src/state/email-digest-query.test.ts` with exactly:

```ts
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
  /** author_id: the user's own contact id (self), or any other contact id. */
  authorId: string;
  /** null = Plot-authored; non-null = connector-synced (bogus link id is fine). */
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
        await sql`INSERT INTO note (id, thread_id, author_id, created_by, link_id, archived_at)
          VALUES (${randomUUID()}::uuid, ${threadId}::uuid, ${n.authorId}::uuid, ${userId}::uuid,
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
    // The recipient's own contact authored the only note — nothing unseen-by-others.
    const { threadId, rows } = await seedAndSelectSelfAuthored();
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
});

/**
 * Variant of seedAndSelect where the only note's author_id is the recipient's
 * OWN contact, so the EXISTS gate (author not in user_contact_ids) must reject it.
 */
async function seedAndSelectSelfAuthored() {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const contactId = randomUUID();
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
        VALUES (${threadId}::uuid, ${userId}::uuid, 'Test thread', ARRAY[${contactId}::uuid]::uuid[], NULL)`.execute(trx);
      await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid)`.execute(trx);
      // author_id = the recipient's OWN contact:
      await sql`INSERT INTO note (id, thread_id, author_id, created_by, link_id, archived_at)
        VALUES (${randomUUID()}::uuid, ${threadId}::uuid, ${contactId}::uuid, ${userId}::uuid, NULL, NULL)`.execute(trx);
      await sql`INSERT INTO thread_state (user_id, thread_id, read_at, importance)
        VALUES (${userId}::uuid, ${threadId}::uuid, NULL, 80)`.execute(trx);
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
```

- [ ] **Step 2: Run the test and confirm the new-behavior cases FAIL**

Prerequisite: local DB up and `$DATABASE_URL` exported (port 54322 in main repo; sanity-check with `psql "$DATABASE_URL" -tAc "show port;"`).

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm test src/state/email-digest-query.test.ts`

Expected: the **"includes…"** and **"already been read"** tests PASS (current query already handles those), but the three exclusion tests — **connector-synced thread**, **only connector-synced note**, **self-authored note** — FAIL, because the un-filtered query still returns those threads.

If instead the whole `describe` is reported as skipped, `$DATABASE_URL` was not passed — fix the env and re-run; do not proceed on a skipped suite.

- [ ] **Step 3: Add the two filter clauses to `selectDigestThreads`**

In `workers/api/src/state/email-digest-query.ts`, insert the two clauses into the `WHERE`, immediately before `ORDER BY tu.updated_at DESC`:

```ts
      AND (
        t.contacts && "user".user_contact_ids(${userId}::uuid)
        OR t.groups && "user".user_group_ids(${userId}::uuid)
      )
      AND t.twist_id IS NULL
      AND EXISTS (
        SELECT 1 FROM note n
        WHERE n.thread_id = t.id
          AND n.link_id IS NULL
          AND n.archived_at IS NULL
          AND NOT (n.author_id = ANY("user".user_contact_ids(tu.user_id)))
      )
    ORDER BY tu.updated_at DESC
```

(The first three lines above are the existing visibility clause, shown for placement; add only the `AND t.twist_id IS NULL` line and the `AND EXISTS (...)` block.)

- [ ] **Step 4: Run the test and confirm ALL cases PASS**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm test src/state/email-digest-query.test.ts`
Expected: all five tests PASS.

- [ ] **Step 5: Confirm no new type errors**

Run: `cd workers/api && pnpm exec tsc`
Expected: no new `error TS` lines for the changed files.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/state/email-digest-query.ts workers/api/src/state/email-digest-query.test.ts
git commit -m "feat(email-notify): only digest unseen Plot-authored threads

Exclude connector-synced threads (thread.twist_id IS NOT NULL) and require
a non-archived Plot-authored note (note.link_id IS NULL) the recipient did
not author, so the unseen-activity email never notifies on connector content.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Finalize

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing update note**

Open `docs/updates.md` and add this bullet to the top (current) section, matching the surrounding plain-language style:

```markdown
- Activity emails now only notify you about new notes written in Plot — items synced from your connected apps (like calendar events and emails) no longer trigger digest emails.
```

- [ ] **Step 2: Run the package lint gate**

Run: `cd workers/api && pnpm lint`
Expected: `tsc` shows no NEW `error TS` lines beyond the 2 pre-existing on `main`; `eslint .` reports no errors on the changed files.

- [ ] **Step 3: Re-run the digest test once more (regression guard)**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm test src/state/email-digest-query.test.ts`
Expected: all five tests PASS.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs(updates): note Plot-only activity emails

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed while writing)

- **Spec coverage:** Requirement 1 (exclude connector threads) → `AND t.twist_id IS NULL` (Task 2 Step 3) + test "excludes a connector-synced thread". Requirement 2 (only send on an unseen Plot note) → `EXISTS` gate (Task 2 Step 3) + tests "only connector-synced note", "authored by the recipient", and the preserved unread clause via "already been read". Spec's "no schema/trigger changes" and "query-only" honored — only TS files touched. Spec test cases 1-5 all mapped.
- **Placeholder scan:** none — all code, SQL, and commands are concrete.
- **Type consistency:** `selectDigestThreads(db, userId)` and `DigestThreadRow` are defined in Task 1 and used identically in Task 2's test and in `email-notify.ts`. `createDb`, `DB`, `sql` all imported from `../db` consistent with `db.ts`'s actual re-exports.

## Notes / risks for the implementer

- The integration test runs only when `$DATABASE_URL` is set. The repo's unit CI job runs without a database, so the suite skips there (the `tsc`/eslint gate still applies). If a CI environment *does* expose `DATABASE_URL`, that DB must have migrations applied and connect as a superuser (for `session_replication_role`); otherwise gate the suite additionally on an explicit opt-in env.
- Seeding disables triggers, so the test exercises the **query**, not the trigger graph that normally populates `thread_priority`/`thread_state`. That is intentional and sufficient for verifying the filter logic.
- No change is needed to what *schedules* the alarm: connector-only activity may still wake the 18h alarm, which now resolves to "no eligible threads → skip".
