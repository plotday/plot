# Connector write-back echo/over-dispatch loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make connector state-mirror write-back callbacks (`onThreadRead`, `onThreadToDo`) fire only when their specific dimension actually changed AND the change did not originate from the connector itself — closing the read/star re-unread loop at the platform level so connectors need no echo KV.

**Architecture:** Add per-dimension change-seqs (`read_seq`, `todo_seq`) and per-dimension write-provenance (`read_source`, `todo_source`) to `public.thread_state`, maintained by a dedicated `BEFORE` trigger. The dispatch views expose `COALESCE(<dim>_seq, seq) AS seq` (cursor code unchanged) and filter out rows whose dimension provenance equals the dispatch target. Provenance is carried into the trigger via a transaction-local GUC set *inside* the `upsert_thread_state`/`clear_thread_state` SQL functions (an autocommit-safe RPC parameter, not a caller-side `set_config`).

**Tech Stack:** PostgreSQL 18 + Atlas migrations (`libs/db`), TypeScript Cloudflare Workers (`workers/api`), Vitest (DB-backed tests against local Postgres), Gmail connector (`public/` submodule).

## Global Constraints

- **Schema workflow (never deviate):** edit `libs/db/schema/**` → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` (auto-runs `pnpm types`) → commit regenerated `libs/db/src/types.ts`. Never hand-write or hand-edit an applied migration. Verify with `pnpm diff-schema-migrations` (must be empty).
- **Expand-only, Squawk-safe:** all DDL goes in `migrations/` (not `migrations-contract/`). Only additive nullable/defaulted columns, `CREATE OR REPLACE` functions/views, trigger swap. No `DROP`, no rename, no `NOT NULL` add, no type narrowing.
- **`thread_state` new columns are nullable with NO default** (`read_seq`/`todo_seq` xid8; `read_source`/`todo_source` uuid). A volatile default would force a full table rewrite; nullable+`COALESCE` fallback = metadata-only DDL, no backfill, cursor continuity free.
- **No new indexes** in this change (every `thread_state` UPDATE is already non-HOT; add expression indexes only if a post-landing `EXPLAIN` shows need).
- **Provenance transport is an RPC parameter**, never a caller-side `set_config` statement — connector write paths run autocommit on `plot.db`, where a separate GUC statement evaporates before the write.
- **Database is LOCAL ONLY.** Use `$DATABASE_URL`. This work needs schema/migration isolation → **execute in a git worktree with its own DB** (see Prerequisite).
- **`withUserDb` is already a transaction** — never nest `.transaction()` inside its callback. The one explicit transaction this plan adds (Task 4, the direct `thread_state` UPDATE) runs on the tool's `this.db` handle, which is NOT inside `withUserDb`.
- Connector changes live in `public/` (submodule) → **separate PR**. Connector packages need **no changeset** (they deploy via `plot deploy`, not npm).
- New `catch` blocks for unexpected errors must call `captureException` (none are required by this plan; note if one arises).

---

## Prerequisite (execution setup)

This plan makes schema/migration changes, so it must run in an isolated worktree with its own Postgres (per `AGENTS.md` "Worktree Development"). Before Task 1:

- Create the worktree (superpowers:using-git-worktrees).
- `bash scripts/worktree-db` to provision the isolated DB, then confirm:
  `psql "$DATABASE_URL" -tAc "show port;"` prints the worktree port (NOT 54322).
- If `worktree-db` ran after the session started, `$DATABASE_URL` may be stale — source `.worktree-db` and override `DATABASE_URL` on every DB command (see `AGENTS.md`).

---

## File Structure

**Schema (`libs/db/schema/`):**
- `50-tables/27-thread_state.sql` — add 4 columns; swap the row trigger to the new function.
- `40-functions/01-common.sql` — add `thread_state_seq_and_updated_at()` trigger function.
- `90-user-schema/85-user-sync-upserts.sql` — add `p_write_source` param + `set_config` to `upsert_thread_state` and `clear_thread_state`; add `p_write_source` to the deferred `pending_thread_state` payload.
- `95-triggers/22-apply_pending_thread_state.sql` — replay `p_write_source` from the stashed payload.
- `70-views/75-twist-instance-thread-read.sql` — `COALESCE(read_seq, seq) AS seq` + `read_source` echo filter.
- `70-views/76-twist-instance-thread-schedule.sql` — `COALESCE(todo_seq, seq) AS seq` + `todo_source` echo filter; fix stale header comment.

**API (`workers/api/src/`):**
- `twist/tools/plot/thread.ts` — `markThreadReadForOwner`, `markThreadUnreadForUsers` pass `p_write_source`.
- `twist/tools/integrations.ts` — `applyThreadToDoForUser` passes `p_write_source` on the active path; wraps the direct read-clearing UPDATE in an explicit transaction that sets the GUC.

**Connector (`public/connectors/gmail/src/`):**
- `sync.ts` — delete the `skip_todo_writeback` set + check/clear. **Keep** `unread:`/`starred:` writes (dual-purpose baselines).

**Tests:**
- `libs/db/.../` — new DB test for the trigger (or a vitest file under `workers/api` that hits the DB; this repo's DB tests live beside their consumers). Use `workers/api/src/twist/tools/plot/thread-state-provenance.test.ts` (new).
- `workers/api/src/twist/tools/twist-instance-writeback-views.test.ts` (new) — view-level per-dimension + echo assertions.
- `workers/api/src/twist/tools/integrations-thread-read.test.ts` (existing) — extend for provenance dispatch.
- `public/connectors/gmail/src/gmail.test.ts` (existing) — round-trip star+read.

---

## Task 1: `thread_state` per-dimension seq + provenance columns and trigger

**Files:**
- Modify: `libs/db/schema/50-tables/27-thread_state.sql`
- Modify: `libs/db/schema/40-functions/01-common.sql`
- Test: `workers/api/src/twist/tools/plot/thread-state-provenance.test.ts` (create)

**Interfaces:**
- Produces: columns `thread_state.read_seq xid8 NULL`, `todo_seq xid8 NULL`, `read_source uuid NULL`, `todo_source uuid NULL`; trigger function `thread_state_seq_and_updated_at()`. Invariant: on UPDATE, `read_seq`/`read_source` change **iff** `read_at` changed; `todo_seq`/`todo_source` change **iff** `active`/`on`/`at` changed. GUC `plot.write_source_twist_instance` (unset → NULL provenance).

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/tools/plot/thread-state-provenance.test.ts`. It seeds a user + thread directly, then drives raw `thread_state` writes and asserts the trigger's per-dimension behavior. Follow the existing DB-test shape in `integrations-thread-read.test.ts` (real `createDb`, a `Rollback` sentinel to roll the seeding txn back).

```ts
import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";
import { createDb, type DB } from "../../../db";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

async function withThread(
  fn: (db: Kysely<DB>, ids: { userId: string; threadId: string }) => Promise<void>,
) {
  const db = createDb({ DATABASE_URL } as never);
  try {
    await db.transaction().execute(async (trx) => {
      const userId = randomUUID();
      const threadId = randomUUID();
      await sql`INSERT INTO public."user" (id) VALUES (${userId})`.execute(trx);
      await sql`INSERT INTO public.thread (id, created_by) VALUES (${threadId}, ${userId})`.execute(trx);
      await fn(trx, { userId, threadId });
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

async function insertState(trx: Kysely<DB>, userId: string, threadId: string) {
  await sql`INSERT INTO public.thread_state (user_id, thread_id, active, read_at)
            VALUES (${userId}, ${threadId}, false, now())`.execute(trx);
}

async function readRow(trx: Kysely<DB>, userId: string, threadId: string) {
  const r = await sql<{
    seq: string; read_seq: string | null; todo_seq: string | null;
    read_source: string | null; todo_source: string | null; read_at: Date | null;
  }>`SELECT seq::text, read_seq::text, todo_seq::text,
            read_source::text, todo_source::text, read_at
       FROM public.thread_state WHERE user_id=${userId} AND thread_id=${threadId}`.execute(trx);
  return r.rows[0];
}

describe.skipIf(!DATABASE_URL)("thread_state per-dimension trigger", () => {
  it("read change bumps read_seq only; todo change bumps todo_seq only", async () => {
    await withThread(async (trx, { userId, threadId }) => {
      await insertState(trx, userId, threadId);
      const before = await readRow(trx, userId, threadId);

      // Change read_at only.
      await sql`UPDATE public.thread_state SET read_at = NULL
                WHERE user_id=${userId} AND thread_id=${threadId}`.execute(trx);
      const afterRead = await readRow(trx, userId, threadId);
      expect(afterRead.read_seq).not.toBe(before.read_seq);
      expect(afterRead.todo_seq).toBe(before.todo_seq);

      // Change active only.
      await sql`UPDATE public.thread_state SET active = TRUE
                WHERE user_id=${userId} AND thread_id=${threadId}`.execute(trx);
      const afterTodo = await readRow(trx, userId, threadId);
      expect(afterTodo.todo_seq).not.toBe(afterRead.todo_seq);
      expect(afterTodo.read_seq).toBe(afterRead.read_seq);
    });
  });

  it("stamps provenance from the GUC on the changed dimension only", async () => {
    await withThread(async (trx, { userId, threadId }) => {
      await insertState(trx, userId, threadId);
      const inst = randomUUID();
      // set_config in the same statement batch as the UPDATE so the trigger sees it.
      await sql`SELECT set_config('plot.write_source_twist_instance', ${inst}, true)`.execute(trx);
      await sql`UPDATE public.thread_state SET read_at = NULL
                WHERE user_id=${userId} AND thread_id=${threadId}`.execute(trx);
      const row = await readRow(trx, userId, threadId);
      expect(row.read_source).toBe(inst);
      expect(row.todo_source).toBeNull(); // todo dimension untouched → no provenance
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/plot/thread-state-provenance.test.ts`
Expected: FAIL — `column "read_seq" does not exist`.

- [ ] **Step 3: Add the trigger function**

In `libs/db/schema/40-functions/01-common.sql`, after `thread_priority_seq_and_updated_at` (ends ~line 82), add:

```sql
-- thread_state variant: besides the base seq/updated_at bump, it maintains
-- two PER-DIMENSION change cursors and their write-provenance so connector
-- write-back dispatch fires only on real, non-echoed transitions:
--   read_seq/read_source  — advance iff read_at changes
--   todo_seq/todo_source  — advance iff active/on/at change
-- *_source = the connector twist_instance that caused the write (via the
-- plot.write_source_twist_instance GUC set inside upsert/clear_thread_state),
-- or NULL for Plot-side (user/AI) writes. See the two twist_instance_thread_*
-- views (COALESCE(<dim>_seq, seq) cursor + "<dim>_source IS DISTINCT FROM pt.id"
-- echo filter). Nullable seq columns COALESCE to `seq` for pre-feature rows.
CREATE OR REPLACE FUNCTION thread_state_seq_and_updated_at ()
    RETURNS TRIGGER
    AS $$
DECLARE
    v_source uuid;
BEGIN
    v_source := NULLIF(current_setting('plot.write_source_twist_instance', TRUE), '')::uuid;

    -- Activity-only maintenance suppresses the cursor (mirrors
    -- update_seq_and_updated_at). Preserve ALL per-dimension bookkeeping too.
    IF TG_OP = 'UPDATE'
       AND current_setting('plot.skip_activity_seq', TRUE) = 'on' THEN
        NEW.updated_at = OLD.updated_at;
        NEW.seq = OLD.seq;
        NEW.read_seq = OLD.read_seq;
        NEW.read_source = OLD.read_source;
        NEW.todo_seq = OLD.todo_seq;
        NEW.todo_source = OLD.todo_source;
        RETURN NEW;
    END IF;

    NEW.updated_at = now();
    NEW.seq = pg_current_xact_id();

    IF TG_OP = 'UPDATE' THEN
        IF NEW.read_at IS DISTINCT FROM OLD.read_at THEN
            NEW.read_seq = pg_current_xact_id();
            NEW.read_source = v_source;
        ELSE
            NEW.read_seq = OLD.read_seq;
            NEW.read_source = OLD.read_source;
        END IF;

        IF NEW.active IS DISTINCT FROM OLD.active
           OR NEW."on" IS DISTINCT FROM OLD."on"
           OR NEW."at" IS DISTINCT FROM OLD."at" THEN
            NEW.todo_seq = pg_current_xact_id();
            NEW.todo_source = v_source;
        ELSE
            NEW.todo_seq = OLD.todo_seq;
            NEW.todo_source = OLD.todo_source;
        END IF;
    ELSE
        -- INSERT: both dimensions are newly established by this writer.
        NEW.read_seq = pg_current_xact_id();
        NEW.read_source = v_source;
        NEW.todo_seq = pg_current_xact_id();
        NEW.todo_source = v_source;
    END IF;

    RETURN NEW;
END;
$$
LANGUAGE plpgsql;
```

- [ ] **Step 4: Add the columns and swap the trigger**

In `libs/db/schema/50-tables/27-thread_state.sql`, add the columns inside the `CREATE TABLE` (after `"seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),`):

```sql
    -- Per-dimension change cursors + write-provenance for connector write-back
    -- dispatch. Nullable, no default (metadata-only DDL, no rewrite): views
    -- COALESCE(<dim>_seq, seq). Maintained by thread_state_seq_and_updated_at.
    "read_seq" xid8,
    "todo_seq" xid8,
    "read_source" uuid,
    "todo_source" uuid,
```

Then change the trigger's function:

```sql
CREATE TRIGGER set_thread_state_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_state"
    FOR EACH ROW EXECUTE FUNCTION thread_state_seq_and_updated_at();
```

- [ ] **Step 5: Generate and apply the migration**

Run:
```bash
cd libs/db && pnpm gen-migration -- thread_state_per_dimension_seq_provenance
pnpm apply-migrations
```
Expected: migration created in `libs/db/migrations/`, applied cleanly, `pnpm types` regenerates `libs/db/src/types.ts` (now shows the 4 new columns).

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/plot/thread-state-provenance.test.ts`
Expected: PASS (both cases).

- [ ] **Step 7: Verify schema/migration sync**

Run: `cd libs/db && pnpm diff-schema-migrations`
Expected: no differences.

- [ ] **Step 8: Commit**

```bash
git add libs/db/schema/50-tables/27-thread_state.sql libs/db/schema/40-functions/01-common.sql \
        libs/db/migrations/ libs/db/src/types.ts \
        workers/api/src/twist/tools/plot/thread-state-provenance.test.ts
git commit -m "feat(db): per-dimension seq + provenance on thread_state"
```

---

## Task 2: Provenance parameter on the write functions + deferred replay

**Files:**
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` (`upsert_thread_state`, `clear_thread_state`)
- Modify: `libs/db/schema/95-triggers/22-apply_pending_thread_state.sql`
- Test: `workers/api/src/twist/tools/plot/thread-state-provenance.test.ts` (extend)

**Interfaces:**
- Consumes: Task 1 columns + trigger + GUC name.
- Produces: `user.upsert_thread_state(..., p_write_source uuid DEFAULT NULL)` and `user.clear_thread_state(..., p_write_source uuid DEFAULT NULL)` — both `set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text,''), true)` as their first statement. Deferred payload carries `p_write_source`.

- [ ] **Step 1: Write the failing test (autocommit path)**

Append to `thread-state-provenance.test.ts`. This calls the SQL functions the way production does — a single autocommit statement per call (no surrounding transaction) — which is the case a manual-GUC test would miss. Reuse `createDb` directly (no wrapping txn), and clean up the row at the end.

```ts
import { rpcUser } from "../../../rpc";

describe.skipIf(!DATABASE_URL)("provenance via RPC parameter (autocommit)", () => {
  it("clear_thread_state stamps read_source from p_write_source", async () => {
    const db = createDb({ DATABASE_URL } as never);
    const userId = randomUUID();
    const threadId = randomUUID();
    const priorityId = randomUUID();
    const inst = randomUUID();
    try {
      await sql`INSERT INTO public."user" (id) VALUES (${userId})`.execute(db);
      await sql`INSERT INTO public.priority (id, user_id) VALUES (${priorityId}, ${userId})`.execute(db);
      await sql`INSERT INTO public.thread (id, created_by) VALUES (${threadId}, ${userId})`.execute(db);
      await sql`INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
                VALUES (${threadId}, ${userId}, ${priorityId})`.execute(db);

      await rpcUser(db, "clear_thread_state", {
        user_id: userId,
        p_thread_id: threadId,
        p_write_source: inst,
      });

      const r = await sql<{ read_source: string | null }>`
        SELECT read_source::text FROM public.thread_state
        WHERE user_id=${userId} AND thread_id=${threadId}`.execute(db);
      expect(r.rows[0]?.read_source).toBe(inst);
    } finally {
      await sql`DELETE FROM public.thread WHERE id=${threadId}`.execute(db);
      await sql`DELETE FROM public.priority WHERE id=${priorityId}`.execute(db);
      await sql`DELETE FROM public."user" WHERE id=${userId}`.execute(db);
      await db.destroy();
    }
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/plot/thread-state-provenance.test.ts -t "provenance via RPC"`
Expected: FAIL — function has no `p_write_source` argument (rpc error) OR `read_source` is NULL.

- [ ] **Step 3: Add `p_write_source` to `upsert_thread_state`**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, add the trailing parameter to the signature (after `p_set_at boolean DEFAULT FALSE`):

```sql
    p_set_at boolean DEFAULT FALSE,
    p_write_source uuid DEFAULT NULL
)
```

Add as the first statement after `BEGIN`:

```sql
BEGIN
    -- Provenance for connector write-back echo suppression: stamps the
    -- thread_state trigger via a txn-local GUC (single statement = own txn,
    -- so the trigger fired within the write sees it; '' clears it so it can't
    -- leak to a later RPC in the same withUserDb transaction).
    PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);
```

Extend the deferred payload (`jsonb_build_object(...)`, add before the closing `)`):

```sql
                'p_set_at', p_set_at,
                'p_write_source', p_write_source
            )
```

- [ ] **Step 4: Add `p_write_source` to `clear_thread_state`**

Signature (after `p_bumped_at timestamptz DEFAULT NULL`):

```sql
    p_bumped_at timestamptz DEFAULT NULL,
    p_write_source uuid DEFAULT NULL
)
```

First statement after `BEGIN`:

```sql
BEGIN
    PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);
```

- [ ] **Step 5: Replay provenance from the deferred payload**

In `libs/db/schema/95-triggers/22-apply_pending_thread_state.sql`, add the argument to the `PERFORM "user".upsert_thread_state(...)` call (after the `p_set_at` line):

```sql
        COALESCE((v_payload ->> 'p_set_at')::boolean, FALSE),
        (v_payload ->> 'p_write_source')::uuid
    );
```

- [ ] **Step 6: Generate, apply, verify sync**

```bash
cd libs/db && pnpm gen-migration -- thread_state_write_source_param
pnpm apply-migrations
pnpm diff-schema-migrations   # expect no differences
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/plot/thread-state-provenance.test.ts`
Expected: PASS (all cases, incl. the new autocommit case).

- [ ] **Step 8: Commit**

```bash
git add libs/db/schema/90-user-schema/85-user-sync-upserts.sql \
        libs/db/schema/95-triggers/22-apply_pending_thread_state.sql \
        libs/db/migrations/ libs/db/src/types.ts \
        workers/api/src/twist/tools/plot/thread-state-provenance.test.ts
git commit -m "feat(db): p_write_source provenance param on thread_state write fns"
```

---

## Task 3: Dimension-scoped, echo-filtered dispatch views

**Files:**
- Modify: `libs/db/schema/70-views/75-twist-instance-thread-read.sql`
- Modify: `libs/db/schema/70-views/76-twist-instance-thread-schedule.sql`
- Test: `workers/api/src/twist/tools/twist-instance-writeback-views.test.ts` (create)

**Interfaces:**
- Consumes: Task 1 columns; Task 2 provenance.
- Produces: `twist_instance_thread_read.seq = COALESCE(read_seq, seq)` and only rows where `read_source IS DISTINCT FROM twist_instance_id`; `twist_instance_thread_schedule.seq = COALESCE(todo_seq, seq)` and only rows where `todo_source IS DISTINCT FROM twist_instance_id`. Column names/types unchanged (`seq` stays xid8).

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/tools/twist-instance-writeback-views.test.ts`. Seed a connector-owned thread (a `twist_instance` whose `id` = `thread.created_by`, its `owner_id` a user with a `thread_priority` filing) and assert view behavior. Model the seeding on `integrations-thread-read.test.ts`'s `seed` helper.

```ts
import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";
import { createDb, type DB } from "../../db";
import { rpcUser } from "../../rpc";

const DATABASE_URL = process.env.DATABASE_URL;
class Rollback extends Error {}

async function seed(trx: Kysely<DB>) {
  const ownerId = randomUUID();
  const instId = randomUUID();
  const threadId = randomUUID();
  const priorityId = randomUUID();
  await sql`INSERT INTO public."user" (id) VALUES (${ownerId})`.execute(trx);
  await sql`INSERT INTO public.priority (id, user_id) VALUES (${priorityId}, ${ownerId})`.execute(trx);
  // twist_instance owned by ownerId; thread.created_by = instId.
  await sql`INSERT INTO public.twist (id, name) VALUES (1, 'test')
            ON CONFLICT (id) DO NOTHING`.execute(trx);
  await sql`INSERT INTO public.twist_instance (id, twist_id, owner_id)
            VALUES (${instId}, 1, ${ownerId})`.execute(trx);
  await sql`INSERT INTO public.thread (id, created_by) VALUES (${threadId}, ${instId})`.execute(trx);
  await sql`INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (${threadId}, ${ownerId}, ${priorityId})`.execute(trx);
  return { ownerId, instId, threadId };
}

async function readViewSeq(trx: Kysely<DB>, instId: string, threadId: string) {
  const r = await sql<{ seq: string }>`
    SELECT seq::text FROM public.twist_instance_thread_read
    WHERE twist_instance_id=${instId} AND thread_id=${threadId}`.execute(trx);
  return r.rows[0]?.seq ?? null;
}
async function scheduleViewSeq(trx: Kysely<DB>, instId: string, threadId: string) {
  const r = await sql<{ seq: string }>`
    SELECT seq::text FROM public.twist_instance_thread_schedule
    WHERE twist_instance_id=${instId} AND thread_id=${threadId}`.execute(trx);
  return r.rows[0]?.seq ?? null;
}

async function withSeed(fn: (trx: Kysely<DB>, s: Awaited<ReturnType<typeof seed>>) => Promise<void>) {
  const db = createDb({ DATABASE_URL } as never);
  try {
    await db.transaction().execute(async (trx) => { await fn(trx, await seed(trx)); throw new Rollback(); });
  } catch (e) { if (!(e instanceof Rollback)) throw e; } finally { await db.destroy(); }
}

describe.skipIf(!DATABASE_URL)("write-back dispatch views", () => {
  it("a todo change does NOT advance the read view's seq (per-dimension)", async () => {
    await withSeed(async (trx, { instId, threadId, ownerId }) => {
      // Establish a Plot-side read (source NULL → visible in read view).
      await rpcUser(trx, "clear_thread_state", { user_id: ownerId, p_thread_id: threadId });
      const readSeqBefore = await readViewSeq(trx, instId, threadId);
      const schedSeqBefore = await scheduleViewSeq(trx, instId, threadId);
      expect(readSeqBefore).not.toBeNull();

      // A todo write (active=true) — Plot-side (no source).
      await rpcUser(trx, "upsert_thread_state", {
        user_id: ownerId, p_thread_id: threadId, p_active: true, p_set_active: true,
      });

      expect(await readViewSeq(trx, instId, threadId)).toBe(readSeqBefore); // unchanged
      expect(await scheduleViewSeq(trx, instId, threadId)).not.toBe(schedSeqBefore); // advanced
    });
  });

  it("a connector-provenance read is suppressed from the read view (echo)", async () => {
    await withSeed(async (trx, { instId, threadId, ownerId }) => {
      // Connector marks read inbound (source = instId) → must NOT appear.
      await rpcUser(trx, "clear_thread_state", {
        user_id: ownerId, p_thread_id: threadId, p_write_source: instId,
      });
      expect(await readViewSeq(trx, instId, threadId)).toBeNull();
    });
  });

  it("a Plot-side read IS emitted by the read view", async () => {
    await withSeed(async (trx, { instId, threadId, ownerId }) => {
      await rpcUser(trx, "clear_thread_state", { user_id: ownerId, p_thread_id: threadId });
      expect(await readViewSeq(trx, instId, threadId)).not.toBeNull();
    });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/twist-instance-writeback-views.test.ts`
Expected: FAIL — the read view still advances on the todo change (no per-dimension seq) and still emits the connector-provenance read (no echo filter).

- [ ] **Step 3: Redefine the read view**

Replace the body of `libs/db/schema/70-views/75-twist-instance-thread-read.sql` (keep the leading comment, update it to mention per-dimension seq + echo filter):

```sql
-- Thread read status changes for threads created by each twist.
-- Used to dispatch onThreadRead callbacks to sources.
--
-- Cursor is per-dimension: COALESCE(read_seq, seq) advances only when read_at
-- actually changes, so an unrelated todo/importance write no longer re-fires
-- onThreadRead. read_source IS DISTINCT FROM the twist_instance suppresses the
-- connector's OWN synced-in read/unread from echoing back to it. This view is
-- intentionally NOT owner-scoped (the owner filter lives at connector dispatch;
-- the Plot-tool twist path consumes non-owner reads).
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read"
AS
SELECT
    a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    COALESCE(tu.read_seq, tu.seq) AS seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    JOIN thread_state tu ON tu.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND tu.updated_at > pt.created_at
    AND tu.read_source IS DISTINCT FROM pt.id
ORDER BY
    COALESCE(tu.read_seq, tu.seq) ASC;
```

- [ ] **Step 4: Redefine the schedule view**

Replace the body of `libs/db/schema/70-views/76-twist-instance-thread-schedule.sql`. Fix the stale header comment (it wrongly says todo is derived from `read_at`), add the COALESCE cursor and echo filter, keep the existing owner scoping (`ts.user_id = pt.owner_id`):

```sql
-- Per-user thread_state changes for threads created by each twist.
-- Used to dispatch onThreadToDo callbacks to sources.
--
-- The todo dimension is active/on/at only. `deriveScheduleTodo`
-- (workers/api/src/twist/tools/schedule-todo.ts) deliberately IGNORES read_at
-- — reading a starred thread must not clear the star. Cursor is per-dimension:
-- COALESCE(todo_seq, seq) advances only when active/on/at change, so a pure
-- read write no longer re-fires onThreadToDo. todo_source IS DISTINCT FROM the
-- twist_instance suppresses the connector's own synced-in star from echoing.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule"
AS
SELECT
    a.created_by AS twist_instance_id,
    ts.thread_id,
    ts.user_id,
    ts."on",
    ts."at",
    ts.active,
    ts.read_at,
    ts.updated_at,
    COALESCE(ts.todo_seq, ts.seq) AS seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    JOIN thread_state ts ON ts.thread_id = a.id AND ts.user_id = pt.owner_id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND ts.updated_at > pt.created_at
    AND ts.todo_source IS DISTINCT FROM pt.id
ORDER BY
    COALESCE(ts.todo_seq, ts.seq) ASC;
```

- [ ] **Step 5: Generate, apply, verify sync**

```bash
cd libs/db && pnpm gen-migration -- writeback_views_per_dimension_echo_filter
pnpm apply-migrations
pnpm diff-schema-migrations   # expect no differences
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/twist-instance-writeback-views.test.ts`
Expected: PASS (all three cases).

- [ ] **Step 7: Commit**

```bash
git add libs/db/schema/70-views/75-twist-instance-thread-read.sql \
        libs/db/schema/70-views/76-twist-instance-thread-schedule.sql \
        libs/db/migrations/ libs/db/src/types.ts \
        workers/api/src/twist/tools/twist-instance-writeback-views.test.ts
git commit -m "feat(db): per-dimension + echo-filtered write-back dispatch views"
```

---

## Task 4: Stamp provenance from the connector write paths

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread.ts` (`markThreadReadForOwner` ~line 306, `markThreadUnreadForUsers` ~line 236)
- Modify: `workers/api/src/twist/tools/integrations.ts` (`applyThreadToDoForUser` ~lines 2140 and 2170)
- Test: `workers/api/src/twist/tools/integrations-thread-read.test.ts` (extend), plus reuse Task 3 view test.

**Interfaces:**
- Consumes: Task 2 RPC param; `plot.twistInstanceId` (available on the `Plot`/`Integrations` tool).
- Produces: connector-initiated read/unread/todo writes carry `read_source`/`todo_source = twistInstanceId`, so the Task 3 views suppress them.

- [ ] **Step 1: Write the failing test**

Add to `integrations-thread-read.test.ts` a case proving that after a connector-attributed read write via the real API helper, the read view suppresses it. If the existing file has a `seed` producing `{ threadId, connectorId, ownerId }`, reuse it; assert against `twist_instance_thread_read`.

```ts
it("connector-marked read does not re-emit to the connector (provenance)", async () => {
  const db = createDb({ DATABASE_URL } as never);
  try {
    await db.transaction().execute(async (trx) => {
      const s = await seed(trx); // { threadId, connectorId, ownerId }
      // Simulate the connector inbound read via the same fn markThreadReadForOwner uses.
      await rpcUser(trx, "clear_thread_state", {
        user_id: s.ownerId, p_thread_id: s.threadId, p_write_source: s.connectorId,
      });
      const rows = await sql`SELECT 1 FROM public.twist_instance_thread_read
        WHERE twist_instance_id=${s.connectorId} AND thread_id=${s.threadId}`.execute(trx);
      expect(rows.rows.length).toBe(0);
      throw new Rollback();
    });
  } catch (e) { if (!(e instanceof Rollback)) throw e; } finally { await db.destroy(); }
});
```

- [ ] **Step 2: Run to verify it fails or passes-for-the-wrong-reason**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/integrations-thread-read.test.ts -t "provenance"`
Expected: PASS already at the SQL layer (Task 3 filter) — this asserts the contract the call-site edits must uphold. (If `seed` lacks `connectorId`, adapt to the returned field name.) The call-site edits below make the *production* code actually pass `p_write_source`; verify via Step 6's grep + typecheck.

- [ ] **Step 3: `markThreadReadForOwner` passes provenance**

In `thread.ts`, the `rpcUser(plot.db, "clear_thread_state", {...})` call becomes:

```ts
  await rpcUser(plot.db, "clear_thread_state", {
    user_id: owner.owner_id,
    p_thread_id: threadId,
    p_write_source: plot.twistInstanceId,
  });
```

- [ ] **Step 4: `markThreadUnreadForUsers` passes provenance**

In `thread.ts`, the `rpcUser(db, "upsert_thread_state", {...})` call inside the `for` loop gains the param (add after `p_note_created_at: noteCreatedAt,`):

```ts
        p_note_created_at: noteCreatedAt,
        p_write_source: plot.twistInstanceId,
      });
```

- [ ] **Step 5: `applyThreadToDoForUser` passes provenance on both paths**

In `integrations.ts`, the todo=true `rpcUser(this.db, "upsert_thread_state", {...})` gains (after `p_set_on: true,`):

```ts
        p_set_on: true,
        p_write_source: this.twistInstanceId,
      });
```

The todo=false path currently does a direct `this.db.updateTable("thread_state").set({ read_at: new Date() })...`. Wrap it in an explicit transaction that sets the GUC so the trigger stamps `read_source` (this runs on the tool's `this.db`, which is NOT inside `withUserDb`, so a new transaction is safe):

```ts
    } else {
      await this.db.transaction().execute(async (trx) => {
        await sql`SELECT set_config('plot.write_source_twist_instance', ${this.twistInstanceId}, true)`.execute(trx);
        await trx
          .updateTable("thread_state")
          .set({ read_at: new Date() })
          .where("thread_id", "=", threadId)
          .where("user_id", "=", userId)
          .where("read_at", "is", null)
          .execute();
      });
    }
```

Ensure `sql` is imported from `kysely` at the top of `integrations.ts` (it already imports from kysely — confirm `sql` is in the import list; add it if missing).

- [ ] **Step 6: Verify the wiring (typecheck + grep)**

Run:
```bash
cd workers/api && pnpm exec tsc --noEmit
grep -n "p_write_source" src/twist/tools/plot/thread.ts src/twist/tools/integrations.ts
```
Expected: tsc clean (the new `p_write_source` arg type-checks because Task 2's types regen added it to `UserFns`); grep shows the three RPC call sites carrying it.

- [ ] **Step 7: Run the dispatch tests**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/integrations-thread-read.test.ts src/twist/tools/twist-instance-writeback-views.test.ts`
Expected: PASS (all, including the new provenance case and the existing dispatch cases).

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/twist/tools/plot/thread.ts \
        workers/api/src/twist/tools/integrations.ts \
        workers/api/src/twist/tools/integrations-thread-read.test.ts
git commit -m "feat(api): stamp connector write-back provenance on thread_state writes"
```

---

## Task 5: Remove the Gmail `skip_todo_writeback` KV (public submodule)

**Files:**
- Modify: `public/connectors/gmail/src/sync.ts` (lines ~1433-1434 set; ~1699-1700 check/clear)
- Test: `public/connectors/gmail/src/gmail.test.ts` (extend)

**Interfaces:**
- Consumes: platform echo suppression from Tasks 1-4 (no `onThreadToDo` echo of a Gmail-originated star).
- Produces: `onThreadToDoFn` no longer short-circuits on a local KV flag; the star inbound handler no longer sets it. `unread:`/`starred:` writes stay (inbound baselines).

- [ ] **Step 1: Write the failing/guard test**

In `gmail.test.ts`, add a test asserting `onThreadToDoFn` performs the write-back when invoked (i.e. no longer swallowed by `skip_todo_writeback`) and that a Gmail-originated star still round-trips. Match the file's existing host-stub pattern. Assert `modifyThread` was called for a todo=true dispatch even when no `skip_todo_writeback` key was ever set, and that the inbound star handler does not write a `skip_todo_writeback:*` key.

```ts
it("onThreadToDo writes back without a skip_todo_writeback short-circuit", async () => {
  const { host, api } = makeHost(); // existing helper
  await onThreadToDoFn(host, threadWithMeta, actor, true, {});
  expect(api.modifyThread).toHaveBeenCalledWith(GMAIL_THREAD_ID, ["STARRED", "INBOX"]);
  expect(host.get).not.toHaveBeenCalledWith(expect.stringContaining("skip_todo_writeback"));
});
```
(Adapt helper/const names to `gmail.test.ts`'s conventions.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd public/connectors/gmail && pnpm vitest run src/gmail.test.ts -t "skip_todo_writeback"`
Expected: FAIL — current `onThreadToDoFn` calls `host.get("skip_todo_writeback:...")`.

- [ ] **Step 3: Remove the set in the inbound star handler**

In `sync.ts` around line 1428-1436, delete the `skip_todo_writeback` set (keep the `setThreadToDo` call and the `starred:` set):

```ts
          await host.tools.integrations.setThreadToDo(
            sourceUrl,
            actorId,
            isStarred
          );
        }
        await host.set(`starred:${thread.id}`, isStarred);
```
(Delete the `await host.set(\`skip_todo_writeback:${thread.id}\`, true);` line and its comment.)

- [ ] **Step 4: Remove the check/clear in `onThreadToDoFn`**

In `sync.ts` around lines 1698-1702, delete the guard block:

```ts
  const meta = thread.meta ?? {};
  const threadId = meta.threadId as string;
  const channelId = (meta.channelId ?? meta.syncableId) as string;
  if (!threadId || !channelId) return;

  // Best-effort: if the connection lost its Google auth, skip the star
```
(Delete the `// Loop prevention...` comment and the `if (await host.get(\`skip_todo_writeback:${threadId}\`)) { ... return; }` block. Leave everything else, including the `starred:` write, intact.)

- [ ] **Step 5: Build + test the connector**

Run:
```bash
cd public/connectors/gmail && pnpm build && pnpm vitest run src/gmail.test.ts
```
Expected: build clean; all Gmail tests pass (including the new one).

- [ ] **Step 6: Sweep other connectors for the same pattern (report only)**

Run:
```bash
cd /Users/kris.braun/code/plot
grep -rn "skip_todo_writeback\|skip_.*writeback" public/connectors connectors 2>/dev/null
```
Expected: only Gmail had it. If another connector has a pure outbound-suppression `skip_*` KV, note it for a follow-up (do NOT remove inbound `unread:`/`starred:`-style baselines). Record findings in the PR description; no code change here unless trivially identical to Gmail's.

- [ ] **Step 7: Commit (in the submodule)**

```bash
cd public && git add connectors/gmail/src/sync.ts connectors/gmail/src/gmail.test.ts
git commit -m "feat(gmail): drop skip_todo_writeback; rely on platform echo suppression"
```

---

## Task 6: Finalize

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Verify: repo-wide lint, DB sync, types.

- [ ] **Step 1: Add a user-facing update fragment**

Run: `pnpm updates:new "Fixed threads bouncing back to unread after you read and starred them in Gmail"`
Edit the generated fragment to put the bullet under `### Fixes` (plain language, no internals):

```markdown
### Fixes

- Reading and starring an email in Gmail no longer makes the thread pop back to unread in both Gmail and Plot.
```

- [ ] **Step 2: Lint the changed packages**

Run:
```bash
cd workers/api && pnpm lint
cd ../../libs/db && pnpm lint      # db:lint = types freshness check
cd ../../public/connectors/gmail && pnpm lint
```
Expected: all clean. If `libs/db` lint reports stale types, run `pnpm --filter @plotday/db types` and commit `libs/db/src/types.ts`.

- [ ] **Step 3: Full DB sync + affected test suites**

Run:
```bash
cd libs/db && pnpm diff-schema-migrations                       # empty
cd ../../workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run \
  src/twist/tools/plot/thread-state-provenance.test.ts \
  src/twist/tools/twist-instance-writeback-views.test.ts \
  src/twist/tools/integrations-thread-read.test.ts \
  src/twist/tools/plot/link-unread.test.ts \
  src/app/sync/clear-thread-state-own-notes.test.ts
```
Expected: all pass (the last two are existing read-path suites — regression guard).

- [ ] **Step 4: Run `/finalize` checklist**

Confirm: no new uncaptured `catch` blocks; backwards compatibility (old callers omit `p_write_source` → NULL → dispatch, verified in Task 2); public submodule change is a separate PR (Task 5) with **no changeset**; `docs/updates.d/` fragment added.

- [ ] **Step 5: Commit finalization**

```bash
git add docs/updates.d/ libs/db/src/types.ts
git commit -m "docs: update fragment for Gmail read/star re-unread fix"
```

---

## Self-Review

**Spec coverage:**
- §1 per-dimension seqs (nullable, no default, COALESCE) → Task 1 (columns) + Task 3 (views COALESCE). ✓
- §2 provenance columns → Task 1. ✓
- §3 dedicated trigger (skip_activity_seq preserve incl. new cols; IS DISTINCT per dim; INSERT branch) → Task 1 Step 3. ✓
- §4 views (COALESCE seq, echo filter, read view unscoped, schedule view owner-scoped + comment fix) → Task 3. ✓
- §5 RPC-param transport (both fns set_config; call sites; direct UPDATE explicit txn; NOT caller GUC) → Task 2 + Task 4. ✓
- §5 deferred `pending_thread_state` carries `p_write_source` → Task 2 Steps 3,5. ✓
- §6 delete `skip_todo_writeback` ONLY, keep `unread:`/`starred:`; sweep other connectors → Task 5. ✓
- Migration (expand-only, metadata-only, cursor continuity, no indexes, deploy-window safety) → Tasks 1-3 gen/apply + Global Constraints. ✓
- Testing (trigger unit, provenance autocommit, deferred replay, dispatch/view regression, connector round-trip) → Tasks 1-5 + Task 6 Step 3. ✓ (Deferred-replay assertion is covered structurally by Task 2's payload+applier edits; add an explicit deferred-replay test case in Task 2 if the reviewer wants belt-and-braces — the pending path requires seeding a thread with no usable `thread_priority`, then inserting one to trigger the flush.)
- Generalization (schedule_contact/note_reaction) → explicitly OUT of this plan's scope (spec "follow-up"); not tasked. ✓

**Placeholder scan:** No TBD/TODO. All code steps show complete code or exact edits with anchors. Adapt-to-existing-helper notes (Tasks 4/5) point at named existing helpers (`seed`, `makeHost`) rather than inventing them.

**Type consistency:** `p_write_source` used identically across the two SQL functions, the applier, and all three TS call sites. View `seq` column stays xid8 via COALESCE (matches `getSyncSeqExpr` expectations, unchanged). GUC name `plot.write_source_twist_instance` identical in trigger (Task 1), both functions (Task 2), and the direct-UPDATE txn (Task 4).

**Known adaptation points (not gaps):** exact seed-helper field names in `integrations-thread-read.test.ts` and host-stub names in `gmail.test.ts` must be matched to those files at implementation time — the plan flags each inline.
