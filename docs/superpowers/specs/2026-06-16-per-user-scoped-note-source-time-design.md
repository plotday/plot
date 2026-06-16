# Per-user source-time denormalization for scoped notes

**Date:** 2026-06-16
**Status:** Design approved, pending spec review
**Scope:** Server-only (PostgreSQL schema). No Flutter/Drift changes.

## Problem

A thread's row in the app (`ThreadWidget`) shows a relative time that can disagree
with the relative time on its most recent note. Example
(`/t/CbwjpdeY7R7mRPeiFtCKM`): the header reads "4 days ago" while the only note
reads "6 days ago".

- The note footer uses the note's own `source_created_at`
  (`apps/plot/lib/widget/note_viewer.dart:126`, `note.dart:247`) — the true
  source time (e.g. when the email was sent / event created).
- The header uses `thread.contentTimestamp = lastNoteSourceCreatedAt ?? createdAt`
  (`apps/plot/lib/store/thread.dart:4856`, displayed at
  `apps/plot/lib/widget/thread.dart:530`).

When `lastNoteSourceCreatedAt` is NULL, the header falls back to the thread's
`created_at` (Plot ingest time) instead of the note's source time.

### Root cause

`thread.last_note_source_created_at` is a denormalized cache of
`MAX(note.source_created_at)` maintained by the `update_thread_on_note_change`
trigger (`libs/db/schema/50-tables/25-note.sql`). That trigger **only bumps the
shared `thread.last_note_*` columns for unscoped notes** (`access_contacts IS NULL
AND access_groups IS NULL`). For **scoped** notes (a private/visibility-limited
note, e.g. a synced email or a private reply) it deliberately takes the `ELSE`
branch and bumps per-user `thread_state` instead — bumping the shared column
would re-emit/re-sort the thread for users who cannot see the note, leaking its
existence.

Consequence: a thread whose only (or latest) notes are scoped has
`thread.last_note_source_created_at = NULL`. The client's synced
`lastNoteSourceCreatedAt` is therefore NULL, and the header shows ingest time.
In the local dev DB this affects **189 of 358** threads with visible notes — 100%
of them threads whose notes are entirely access-scoped (synced email/calendar).

### Why it is mostly cosmetic today (but worth fixing)

`last_note_source_created_at` is **not** essential to sync correctness:

- **Sync cursor** is the composed `user.thread.seq =
  GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, 0))`
  (`libs/db/schema/90-user-schema/30-thread.sql:40`). A scoped reply bumps
  `thread_state` (`seq xid8 DEFAULT pg_current_xact_id()` +
  `update_seq_and_updated_at` trigger, `50-tables/27-thread_state.sql:36,45`),
  so `ts.seq` advances and the thread re-syncs. A year-old thread that gets a
  scoped reply does **not** fall out of sync.
- **Feed ordering** `activity_at` (`30-thread.sql:91-109`) is
  `COALESCE(GREATEST(last_note_source_created_at, MAX(link.source_created_at),
  ts.bumped_at, schedule_end), created_at)` — backstopped by `link.source_created_at`
  and per-user `ts.bumped_at`, so ordering is correct even when the rollup is NULL.

The one real symptom is the **displayed source time** (header) and the
`read_at` value the client stamps on read (both derive from `contentTimestamp`).

## Goals / non-goals

**Goals**
- The displayed source time for scoped-note threads matches the note footer.
- Server-only: the client's existing synced `last_note_source_created_at`
  column receives the corrected value. No Drift schema / `schemaVersion` change.
- No new write fan-out beyond the per-user write the scoped branch already does.
- Preserve read-stick correctness (the `clear_thread_state` guard).

**Non-goals**
- Changing feed ordering. `activity_at` stays on `bumped_at` (arrival time is the
  right sort key for a reply; source time must not reorder the feed).
- Fixing `last_note_created_at` (ingest-time sibling). It is also NULL for scoped
  threads but only feeds a local MRU-recency heuristic that already falls back to
  `bumped_at`/`created_at`. Decided out of scope (source time only).
- Detecting "scoped but everyone can see it" no-op scoping (a separate, riskier
  optimization to the existing trigger).

## Why server-side projection works with no client changes

Verified in `apps/plot/lib/store/thread.dart` / `note.dart`:

- **Inbound:** sync-ingested threads persist via `fromBase` / `insertOrReplace`
  (`thread.dart:877,892`) and store whatever `user.thread` projects into
  `last_note_source_created_at`. The client does **not** recompute it from
  inbound notes.
- **Local write** to that column (`note.dart:848-854`) fires only for
  *locally-authored* notes (optimistic) and converges with the server value on
  the next sync.
- **Outbound push strips it** (`thread.dart:573-575`), so the client never
  clobbers the server value.

Therefore changing what the `user.thread` view projects flows through to the
client's existing column. The new storage column lives on `public.thread_state`,
which the client never reads directly (it reads the view).

## Design

### 1. Data model

Add one nullable column to `public.thread_state`
(`libs/db/schema/50-tables/27-thread_state.sql`):

```sql
"last_note_source_created_at" timestamptz
```

Semantics: `MAX(note.source_created_at)` over **scoped, visible** notes for this
`(user_id, thread_id)`. NULL when the user has seen no scoped note (the common
case — the shared `thread` column carries it).

Internal column. Not added to any `user.*` view as a new field — it is only an
input to the existing projected column (§3).

### 2. Trigger — scoped branch only

In `update_thread_on_note_change` (`25-note.sql`), the existing `ELSE` (scoped)
branch already upserts `thread_state` for the note's audience. Add the column to
that same write:

```sql
INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at, last_note_source_created_at)
SELECT v.user_id, NEW.thread_id, CASE … END, now(), NEW.source_created_at
FROM ( … audience … ) v
ON CONFLICT (user_id, thread_id) DO UPDATE
SET bumped_at = now(),
    read_at = CASE … END,
    last_note_source_created_at =
        GREATEST(thread_state.last_note_source_created_at, NEW.source_created_at),
    updated_at = now();
```

The **unscoped branch is untouched** — it keeps bumping only the shared
`thread.last_note_source_created_at`. This is the "only denormalize when we have
to" rule, enforced structurally by which branch we edit. No new fan-out: the
scoped branch already writes one `thread_state` row per audience member for the
`bumped_at` bump; we add one `SET` column to that write.

### 3. View projection

`user.thread` (`90-user-schema/30-thread.sql:66`):

```sql
GREATEST(a.last_note_source_created_at, ts.last_note_source_created_at)
    AS last_note_source_created_at,
```

Postgres `GREATEST` skips NULLs:
- unscoped only → shared value
- scoped only → per-user value
- mixed → max of both
- neither → NULL → client falls back to `createdAt` (unchanged)

`ts` is already LEFT JOINed — no new join, no subquery. The two-phase
`/sync/threads` fetch projects this only in phase 2 (≤ `limit` rows).

No change to the view's `seq` / `updated_at` composition: the trigger's
`thread_state` write already bumps `ts.seq` / `ts.updated_at`, so the corrected
value re-syncs on the existing cursor.

`user.thread_redacted` (`30-thread.sql:290`) keeps `NULL::timestamptz AS
last_note_source_created_at` — redaction is unchanged.

### 4. Read-guard threshold — must move in lockstep

`clear_thread_state` (`90-user-schema/85-user-sync-upserts.sql:1131,1144`)
accepts a read only if `p_read_at >= threshold`. The client stamps
`read_at = contentTimestamp = lastNoteSourceCreatedAt ?? createdAt`, so the
threshold must use the **identical formula**:

```sql
p_read_at >= date_trunc('milliseconds',
    COALESCE(GREATEST(t.last_note_source_created_at, ts.last_note_source_created_at),
             t.created_at))
```

`created_at` stays a **COALESCE fallback**, not a `GREATEST` term. This is
load-bearing: a source time earlier than ingest (exactly this bug — Jun 10 source
vs Jun 11 ingest) must **not** raise the threshold above what the client sends, or
every read on a scoped-note thread would be rejected and the thread would stick
unread. `ts` here is the conflicting `thread_state` row (its pre-update value);
the guard only runs on the `ON CONFLICT DO UPDATE` path, where the row exists.
Keep the `date_trunc('milliseconds', …)` wrapper (client/JS ms-precision rule).

### 5. Backfill (one-time, in the expand migration)

`UPDATE`-only (never upsert — creating `thread_state` rows could flip unread
state) existing rows for scoped-note threads:

```sql
UPDATE thread_state ts SET last_note_source_created_at = sub.max_src
FROM (
  SELECT tp.user_id, n.thread_id, MAX(n.source_created_at) AS max_src
  FROM note n
  JOIN thread_priority tp ON tp.thread_id = n.thread_id
  WHERE n.draft = false AND n.archived_at IS NULL
    AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL)
    AND ( tp.user_id = n.created_by
       OR n.access_contacts && "user".user_contact_ids(tp.user_id)
       OR n.access_groups  && "user".user_group_ids(tp.user_id) )
  GROUP BY tp.user_id, n.thread_id
) sub
WHERE ts.user_id = sub.user_id AND ts.thread_id = sub.thread_id;
```

The trigger has already created `thread_state` rows for these audiences, so
`UPDATE`-only is sufficient. The update bumps `ts.seq`, triggering a one-time
re-sync of the affected threads so clients pick up the corrected time. Bounded to
scoped-note threads; batch by `thread_id` ranges if prod volume warrants.

## Explicitly NOT changing

- `activity_at` ordering (stays on `bumped_at`).
- Client / Drift (zero changes; existing column receives the projection).
- Unscoped trigger branch (no per-user writes).
- Notification delivery / digest (gate on importance/urgency, order by
  `thread_state.updated_at` — independent of source time).

## Edge cases (all match existing shared-column semantics)

- **Archive / delete of the latest scoped note:** `GREATEST` is monotonic, so the
  per-user value stays stale-high — identical to the shared column today (the
  trigger no-ops on DELETE and on `archived_at` set).
- **`source_created_at` UPDATE** (e.g. calendar reschedule/cancellation): the
  existing status-change trigger fires (it watches `source_created_at`) and the
  scoped branch advances the per-user value.
- **draft → publish:** status-change trigger fires → first per-user write.
- **Visible user with no `thread_state` row:** they fall back to the shared
  column → `created_at`, exactly as today. No regression. (For scoped notes the
  trigger creates rows for the audience, so this is rare.)

## Migration safety

- Adding a nullable column is a **safe expand migration** (Squawk-clean; no
  `NOT NULL` without default, no drop/rename/type-narrow).
- Schema-file-first workflow: edit `libs/db/schema/`, `pnpm gen-migration`,
  `pnpm apply-migrations`, `pnpm diff-schema-migrations` (clean),
  `pnpm --filter @plotday/db run lint`.
- Trigger / view / function changes are `CREATE OR REPLACE` — additive and
  backward-compatible with currently-deployed workers (they keep reading the same
  column shape; the projected value just becomes correct).
- Regenerate and commit `libs/db/src/types.ts` (`thread_state` gains the column).
- No contract migration needed.

## Testing

pgTAP (and any focused TS), covering:

1. Scoped-note insert sets `thread_state.last_note_source_created_at`, leaves
   `thread.last_note_source_created_at` NULL.
2. Unscoped-note insert leaves the per-user column NULL, sets the shared column.
3. Mixed thread (scoped + unscoped): `user.thread.last_note_source_created_at`
   projects `max(both)`.
4. Neither set → projection NULL (client `createdAt` fallback preserved).
5. **Read-stick regression guard:** a read with `read_at = source_created_at <
   created_at` is accepted post-fix (would be rejected if the guard formula were
   wrong).
6. Backfill populates existing scoped-note `thread_state` rows; re-running is
   idempotent.
7. `user.thread_redacted` still projects NULL.

## Files touched

- `libs/db/schema/50-tables/27-thread_state.sql` — add column (+ comment).
- `libs/db/schema/50-tables/25-note.sql` — trigger scoped branch.
- `libs/db/schema/90-user-schema/30-thread.sql` — view projection.
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` — `clear_thread_state`
  guard.
- `libs/db/migrations/<generated>.sql` — schema diff + backfill data migration.
- `libs/db/src/types.ts` — regenerated.
- `libs/db/test/…` — pgTAP tests.
- `docs/updates.md` — user-facing fix note ("thread times now reflect the
  message's original time").
