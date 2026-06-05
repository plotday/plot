# Thread Assignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any thread be assigned to a contact (`thread.assignee_id`), Plot-only by default, with best-effort two-way sync to assignment-capable link connectors (e.g. Linear).

**Architecture:** A new mutable, synced `thread.assignee_id` is the thread-level source of truth. A sticky `link.supports_assignee` flag + a statement-level trigger mirror the primary (earliest-created) assignment-capable link's assignee into the thread (external wins). User edits on connector threads write the link (riding the existing `onLinkUpdated` dispatch → Linear write-back); Plot-only edits write the thread directly. Flutter splits the overloaded `SharedCommandButton` into reusable `ThreadAssignee` + `ThreadSharing` widgets, adds an `AssignThread` hover command and a connection-aware assignee picker, and adds an Assignee search filter.

**Tech Stack:** PostgreSQL (Atlas migrations, pgTAP), Drift/SQLite (Flutter), Dart/Flutter (forui), TypeScript (Cloudflare Workers + Linear connector in the `public/` submodule).

**Spec:** `docs/superpowers/specs/2026-06-05-thread-assignment-design.md`

---

## Pre-flight (read once before starting)

- **Database port:** All DB commands use `$DATABASE_URL`. If in a worktree, verify the port first: `psql "$DATABASE_URL" -tAc "show port;"` (must NOT be 54322 if you're in a worktree where `worktree-db` ran). See `libs/db/AGENTS.md` "Stale `$DATABASE_URL`".
- **Schema-change workflow (never deviate):** edit `libs/db/schema/*` → `pnpm gen-migration -- <name>` → (append data backfill if needed) → `pnpm apply-migrations` (auto-runs `pnpm types`) → `pnpm diff-schema-migrations` (must be clean) → commit `libs/db/src/types.ts` + migration + `libs/db/migrations/atlas.sum`.
- **Flutter codegen:** after editing any `lib/store/*` table, run `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs` then `flutter analyze`.
- **public/ submodule:** the Linear change (Phase 2) is a separate branch/PR inside `public/`. No changeset is required (only `public/twister/src/` changes need changesets). After it merges, bump the submodule pointer in the core repo.

## File Structure

**Database (`libs/db/`):**
- Modify `schema/50-tables/24-thread.sql` — add `assignee_id` column.
- Modify `schema/50-tables/25-link.sql` — add `supports_assignee` column.
- Modify `schema/90-user-schema/30-thread.sql` — surface `assignee_id` in `user.thread` + `user.thread_redacted`.
- Modify `schema/90-user-schema/80-upsert_thread.sql` — mutable `assignee_id`.
- Modify `schema/90-user-schema/80-upsert_link.sql` — sticky `supports_assignee`.
- Create `schema/60-functions/<n>-recompute_thread_assignee.sql` — recompute helper.
- Create `schema/95-triggers/<n>-link-assignee-thread-mirror.sql` — mirror triggers.
- Create `tests/45-thread-assignee-mirror.sql` — pgTAP coverage.
- Generated: `migrations/<ts>_thread_assignee.sql`, `src/types.ts`.

**Flutter (`apps/plot/`):**
- Modify `lib/store/thread.dart` — `assigneeId` Drift column, `Thread.updateAssignee`, `_buildFeedFilter` assignee predicate.
- Modify `lib/store/store.dart` — `schemaVersion` bump + migration step.
- Modify `lib/store/link.dart` — `Link.getForConnection` helper.
- Create `lib/widget/thread_assignee.dart` — `ThreadAssignee` widget + `pickThreadAssignee`.
- Create `lib/widget/thread_sharing.dart` — `ThreadSharing` widget.
- Modify `lib/widget/thread.dart` — use new widgets in `ThreadCommands`; delete `SharedCommandButton`.
- Modify `lib/page/thread.dart` — header `_ThreadActionsRow`.
- Modify `lib/command/thread.dart` — `AssignThread` command.
- Modify `lib/state/priority_state.dart` + `lib/state/priority.dart` + `lib/command/filter.dart` + `lib/widget/unified_header.dart` — assignee filter.

**Connector (`public/connectors/linear/`):**
- Modify `src/linear.ts` — wire `onLinkUpdated` to write back assignee.

---

# Phase 1 — Database & sync

### Task 1: Write the failing pgTAP test for the mirror trigger

**Files:**
- Create: `libs/db/tests/45-thread-assignee-mirror.sql`

- [ ] **Step 1: Write the test**

Model the structure on the existing `libs/db/tests/43-schedule-sync-trigger-write.sql`. Use a transaction + `plan` + `rollback`. The test seeds a thread and links directly (server tables), then asserts the trigger behavior.

```sql
BEGIN;
SELECT plan(5);

-- Seed a user, contacts, a thread, and links.
INSERT INTO "user" (id) VALUES ('00000000-0000-0000-0000-0000000000a1')
  ON CONFLICT DO NOTHING;
INSERT INTO contact (id, name) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'Alice'),
  ('00000000-0000-0000-0000-0000000000c2', 'Bob')
  ON CONFLICT DO NOTHING;

INSERT INTO thread (id, created_by) VALUES
  ('00000000-0000-0000-0000-0000000000t1', '00000000-0000-0000-0000-0000000000a1');

-- 1. A capable link with an assignee mirrors onto the thread.
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000l1',
        '00000000-0000-0000-0000-0000000000t1',
        now() - interval '2 min', true,
        '00000000-0000-0000-0000-0000000000c1');
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000t1'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'capable link assignee mirrors onto thread');

-- 2. The EARLIEST capable link wins, not a later one.
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000l2',
        '00000000-0000-0000-0000-0000000000t1',
        now() - interval '1 min', true,
        '00000000-0000-0000-0000-0000000000c2');
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000t1'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'earliest capable link wins');

-- 3. External unassign on the primary link mirrors NULL.
UPDATE link SET assignee_id = NULL WHERE id = '00000000-0000-0000-0000-0000000000l1';
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000t1'),
  NULL::uuid,
  'external unassign mirrors NULL (sticky capability)');

-- 4. A NON-capable link never clobbers a Plot-only assignment.
INSERT INTO thread (id, created_by, assignee_id) VALUES
  ('00000000-0000-0000-0000-0000000000t2',
   '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000c1');
INSERT INTO link (id, thread_id, created_at, supports_assignee, assignee_id)
VALUES ('00000000-0000-0000-0000-0000000000l3',
        '00000000-0000-0000-0000-0000000000t2',
        now(), false, NULL);
SELECT is(
  (SELECT assignee_id FROM thread WHERE id = '00000000-0000-0000-0000-0000000000t2'),
  '00000000-0000-0000-0000-0000000000c1'::uuid,
  'non-capable link does not clobber Plot-only assignment');

-- 5. upsert_link sets supports_assignee sticky when an assignee is written.
SELECT lives_ok($$
  SELECT "user".upsert_link(
    '00000000-0000-0000-0000-0000000000a1',
    jsonb_build_object(
      'thread_id', '00000000-0000-0000-0000-0000000000t2',
      'assignee_id', '00000000-0000-0000-0000-0000000000c2'))
$$, 'upsert_link with assignee succeeds');

SELECT finish();
ROLLBACK;
```

Note: adjust seed columns to satisfy NOT-NULL constraints actually present in `contact` / `thread` / `link` (check the table files; the `thread_author_id` plan notes connector seeds need NOT-NULL `name`/`handle`/`user_id`). Keep the assertions identical.

- [ ] **Step 2: Run the test — expect failure**

```bash
cd libs/db && pg_prove -d "$DATABASE_URL" tests/45-thread-assignee-mirror.sql
```
Expected: FAIL — `column "assignee_id" of relation "thread" does not exist` (and `supports_assignee` missing). This confirms the test exercises unbuilt behavior.

- [ ] **Step 3: Commit the test**

```bash
git add libs/db/tests/45-thread-assignee-mirror.sql
git commit -m "test(db): failing pgTAP for thread.assignee_id mirror trigger"
```

---

### Task 2: Add the columns

**Files:**
- Modify: `libs/db/schema/50-tables/24-thread.sql`
- Modify: `libs/db/schema/50-tables/25-link.sql:36` (after `assignee_id`)

- [ ] **Step 1: Add `thread.assignee_id`**

In `24-thread.sql`, add to the column list (place near `icon`):

```sql
    -- Thread-level assignee (contact id). Mutable, user-settable, synced.
    -- Mirrors the primary assignment-capable link's assignee for connector
    -- threads (see link-assignee-thread-mirror trigger); Plot-managed otherwise.
    "assignee_id" uuid,
```

- [ ] **Step 2: Add `link.supports_assignee`**

In `25-link.sql`, immediately after the `"assignee_id" uuid,` line (line 36):

```sql
    -- Sticky capability flag: TRUE once this link has carried an assignee.
    -- Set by upsert_link; used by the mirror trigger to identify
    -- assignment-capable links (only such connectors ever set an assignee).
    "supports_assignee" boolean NOT NULL DEFAULT false,
```

- [ ] **Step 3: Verify schema parses (no DB change yet)**

```bash
cd libs/db && pnpm diff-schema-migrations
```
Expected: it reports a pending diff (the two new columns) — meaning the schema files changed and a migration is needed. (Do not generate yet; later tasks add more.)

---

### Task 3: Surface `assignee_id` in the user views

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-thread.sql` (~line 63 in `user.thread`; ~line 275 in `user.thread_redacted`)

- [ ] **Step 1: Add to `user.thread`**

In the `user.thread` SELECT list, after `a.icon,`:

```sql
    a.icon,
    a.assignee_id,
```

- [ ] **Step 2: Add to `user.thread_redacted`**

In the `user.thread_redacted` SELECT list, after `NULL::text AS icon,`:

```sql
    NULL::text AS icon,
    NULL::uuid AS assignee_id,
```

(Column order must match between the two views — keep `assignee_id` in the same position.)

---

### Task 4: Make `assignee_id` mutable in `upsert_thread`

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_thread.sql` (INSERT column list ~360; VALUES ~390; ON CONFLICT ~492)

- [ ] **Step 1: Add to the INSERT column list (line ~360-361)**

Append `assignee_id` to the column list:

```sql
    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
        draft, key, icon, twist_id, pending_contacts, team_id, embedding, assignee_id
    )
```

- [ ] **Step 2: Add the VALUES entry**

After the `embedding` value (the `NULLIF(...)::halfvec` line ~405), add a comma and:

```sql
        NULLIF(COALESCE(p_thread ->> 'embedding', p_defaults ->> 'embedding'), '')::halfvec,
        COALESCE((p_thread ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_existing.assignee_id)
    )
```

- [ ] **Step 3: Add the ON CONFLICT assignment**

In the `DO UPDATE SET` list (after the `icon = ...` block, ~line 500), add:

```sql
            assignee_id = CASE WHEN p_thread ? 'assignee_id' THEN
                (p_thread ->> 'assignee_id')::uuid
            ELSE
                thread.assignee_id
            END,
```

(Present-key semantics: clients set it explicitly; connectors that never send `assignee_id` leave it untouched — the mirror trigger owns it for connector threads.)

---

### Task 5: Make `supports_assignee` sticky in `upsert_link`

**Files:**
- Modify: `libs/db/schema/90-user-schema/80-upsert_link.sql` (INSERT ~159-178; ON CONFLICT ~191-259)

- [ ] **Step 1: Add `supports_assignee` to the INSERT column list + value**

Add the column to the list (line ~159-162) and its value `(v_assignee_id IS NOT NULL)` to the VALUES (after the `channel_id` value, line ~178):

```sql
    INSERT INTO link (id, thread_id, source, sources, source_created_at, author_id, twist_id,
        created_by, updated_by, sync_depth, title, preview, assignee_id, type, status,
        actions, meta, source_url, merged_from_thread_id, related_source,
        channel_id, supports_assignee)
```

```sql
            COALESCE(p_link ->> 'channel_id', p_defaults ->> 'channel_id'),
            (v_assignee_id IS NOT NULL))
```

- [ ] **Step 2: Add the sticky ON CONFLICT assignment**

After the `channel_id = CASE ... END` block (~line 259), add:

```sql
            channel_id = CASE WHEN p_link ? 'channel_id' THEN
                p_link ->> 'channel_id'
            ELSE
                link.channel_id
            END,
            -- Sticky: once true, stays true. Flips true the first time an
            -- assignee is written (only assignment-capable connectors do).
            supports_assignee = link.supports_assignee
                OR (CASE WHEN p_link ? 'assignee_id' THEN
                        (p_link ->> 'assignee_id')::uuid
                    ELSE
                        COALESCE(v_assignee_id, link.assignee_id)
                    END) IS NOT NULL
```

(Note: the `channel_id` block is shown for anchoring — it already exists; only the `supports_assignee = ...` clause is new. Ensure the preceding clause keeps its trailing comma.)

---

### Task 6: Recompute helper + mirror triggers

**Files:**
- Create: `libs/db/schema/60-functions/40-recompute_thread_assignee.sql`
- Create: `libs/db/schema/95-triggers/30-link-assignee-thread-mirror.sql`

(Pick the numeric prefixes to slot after existing files in each dir — `60-functions/` and `95-triggers/`. Adjust if those exact numbers are taken; ordering within the dir only needs tables to exist first, which they do.)

- [ ] **Step 1: Write the recompute function**

`60-functions/40-recompute_thread_assignee.sql`:

```sql
-- Recompute thread.assignee_id for the given threads from their EARLIEST
-- assignment-capable (supports_assignee = true), non-archived link.
-- Threads with no capable link are left untouched (Plot-managed assignment).
-- The IS DISTINCT FROM guard avoids redundant writes (and redundant seq bumps),
-- which also makes the connector write-back loop-safe.
CREATE OR REPLACE FUNCTION public.recompute_thread_assignee(p_thread_ids uuid[])
    RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE thread t
    SET assignee_id = pc.assignee_id
    FROM (
        SELECT DISTINCT ON (l.thread_id) l.thread_id, l.assignee_id
        FROM link l
        WHERE l.thread_id = ANY (p_thread_ids)
          AND l.supports_assignee = true
          AND l.archived_at IS NULL
        ORDER BY l.thread_id, l.created_at ASC
    ) pc
    WHERE t.id = pc.thread_id
      AND t.assignee_id IS DISTINCT FROM pc.assignee_id;
END;
$$;
```

- [ ] **Step 2: Write the triggers (one per op — transition tables are op-specific)**

`95-triggers/30-link-assignee-thread-mirror.sql`:

```sql
-- AFTER INSERT/UPDATE/DELETE on link → recompute affected threads' assignee.
-- Statement-level (bulk writes recompute each thread once). Separate triggers
-- because NEW TABLE / OLD TABLE references are fixed per operation.

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_ins() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(
        ARRAY(SELECT DISTINCT thread_id FROM new_table WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_upd() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(ARRAY(
        SELECT DISTINCT thread_id FROM (
            SELECT thread_id FROM new_table
            UNION
            SELECT thread_id FROM old_table
        ) x WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_del() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(
        ARRAY(SELECT DISTINCT thread_id FROM old_table WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE TRIGGER link_assignee_mirror_ins
    AFTER INSERT ON link
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_ins();

CREATE TRIGGER link_assignee_mirror_upd
    AFTER UPDATE ON link
    REFERENCING NEW TABLE AS new_table OLD TABLE AS old_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_upd();

CREATE TRIGGER link_assignee_mirror_del
    AFTER DELETE ON link
    REFERENCING OLD TABLE AS old_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_del();
```

---

### Task 7: Generate the migration, backfill, apply, and pass the test

**Files:**
- Generated: `libs/db/migrations/<ts>_thread_assignee.sql`, `libs/db/src/types.ts`, `libs/db/migrations/atlas.sum`

- [ ] **Step 1: Generate the migration**

```bash
cd libs/db && pnpm gen-migration -- thread_assignee
```
Expected: a new file in `migrations/` containing the two `ADD COLUMN`s, the recompute function, and the three triggers. All additive → safe for the Squawk gate.

- [ ] **Step 2: Append the backfill to the generated migration**

At the END of the generated migration file, add:

```sql
-- Backfill: mark links that currently carry an assignee as capable...
UPDATE link SET supports_assignee = true WHERE assignee_id IS NOT NULL;

-- ...then mirror each thread's earliest capable link assignee onto the thread.
UPDATE thread t
SET assignee_id = sub.assignee_id
FROM (
    SELECT DISTINCT ON (l.thread_id) l.thread_id, l.assignee_id
    FROM link l
    WHERE l.supports_assignee = true AND l.archived_at IS NULL AND l.thread_id IS NOT NULL
    ORDER BY l.thread_id, l.created_at ASC
) sub
WHERE t.id = sub.thread_id;

-- Bump every thread so existing clients re-pull the new column.
UPDATE thread SET updated_at = now();
```

- [ ] **Step 3: Re-hash (the manual edit changed the migration)**

```bash
cd libs/db && atlas migrate hash --dir file://migrations
```

- [ ] **Step 4: Apply + regen types**

```bash
cd libs/db && pnpm apply-migrations
```
Expected: migration applies cleanly; `pnpm types` runs automatically and updates `src/types.ts` (now includes `assignee_id` on `thread` and `supports_assignee` on `link`).

- [ ] **Step 5: Run the pgTAP test — expect PASS**

```bash
cd libs/db && pg_prove -d "$DATABASE_URL" tests/45-thread-assignee-mirror.sql
```
Expected: `ok 1..5`, all pass.

- [ ] **Step 6: Verify schema/migration sync**

```bash
cd libs/db && pnpm diff-schema-migrations && pnpm --filter @plotday/db run lint
```
Expected: no diff; types lint passes.

- [ ] **Step 7: Commit**

```bash
git add libs/db/schema libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): thread.assignee_id + link.supports_assignee mirror + backfill"
```

---

### Task 8: Drift `assignee_id` column + `Thread.updateAssignee`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (Threads table, after the `icon` column ~line 117; add `updateAssignee`)
- Modify: `apps/plot/lib/store/store.dart` (`schemaVersion` line 2411; migration tail ~3836)

- [ ] **Step 1: Add the Drift column**

In `thread.dart`, after `TextColumn get icon => text().nullable()();`, mirroring `link.dart`'s `assigneeId`:

```dart
  /// Thread-level assignee (contact id), mirrored from `thread.assignee_id`
  /// on the server. Mutable; for connector threads it tracks the primary
  /// assignment-capable link's assignee.
  BlobColumn get assigneeId =>
      blob().nullable().map(const ActorIdConverter())();
```

(If `ActorIdConverter` isn't already in scope, it's defined in `lib/store/actor.dart` and re-exported via the store barrel — the same import `link.dart` uses.)

- [ ] **Step 2: Add `Thread.updateAssignee` (mirror `Link.updateAssignee`)**

In `thread.dart`, near the other `Thread` mutators:

```dart
  /// Optimistically set the thread-level assignee and push to the server.
  /// Use ONLY for Plot-only threads (no assignment-capable link); connector
  /// threads write the primary link's assignee instead (see pickThreadAssignee).
  static Future<void> updateAssignee(Thread thread, ActorId? newAssigneeId) async {
    final updated = thread._thread.copyWith(
      assigneeId: Value(newAssigneeId),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      Store.get.threads,
      updated.toCompanion(false),
      ThreadsBase(),
    );
  }
```

- [ ] **Step 3: Bump schemaVersion + add migration step**

In `store.dart`, change `int get schemaVersion => 355;` to `356`. Add before the closing brace of `onUpgrade` (after the `if (from < 355)` block):

```dart
    if (from < 356) {
      await _safeAddColumn(m, threads, threads.assigneeId);
    }
```

- [ ] **Step 4: Codegen + analyze**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs && flutter analyze lib/store/thread.dart lib/store/store.dart
```
Expected: codegen succeeds; analyze clean for those files.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/store/store.dart apps/plot/lib/store/*.g.dart
git commit -m "feat(store): sync thread.assigneeId + Thread.updateAssignee"
```

---

# Phase 2 — Linear connector write-back (in `public/`)

### Task 9: Wire `onLinkUpdated` to write back the assignee

**Files:**
- Modify: `public/connectors/linear/src/linear.ts:262-274`

- [ ] **Step 1: Create a branch in the submodule**

```bash
cd public && git checkout -b feat/linear-assignee-writeback
```

- [ ] **Step 2: Replace `onLinkUpdated` to delegate to `updateIssue`**

`updateIssue(link)` already reconciles status, assignee (email→Linear user lookup), and title. Delegating makes `onLinkUpdated` fire for assignee changes (not just status). Replace lines 262-274:

```typescript
  async onLinkUpdated(link: Link): Promise<void> {
    const issueId = link.meta?.linearId as string | undefined;
    const projectId = link.meta?.projectId as string | undefined;
    if (!issueId || !projectId) return;

    // updateIssue reconciles status + assignee (+ title) for this issue.
    // Best-effort: a failed external write is reconciled on the next sync-in
    // (external is the source of truth for assignment).
    try {
      await this.updateIssue(link);
    } catch (error) {
      console.error(
        "[linear] onLinkUpdated write-back failed:",
        error instanceof Error ? error.message : String(error)
      );
    }
  }
```

(`updateIssue` only sets `title` when `link.title` is truthy, and connector-thread titles are immutable in Plot, so this is a no-op for title — it does not overwrite the Linear title with anything new.)

- [ ] **Step 3: Build + typecheck**

```bash
cd public/connectors/linear && pnpm build && pnpm exec tsc --noEmit
```
Expected: builds clean, no type errors.

- [ ] **Step 4: Commit in the submodule**

```bash
cd public && git add connectors/linear/src/linear.ts
git commit -m "feat(linear): write back assignee changes via onLinkUpdated"
```

(Do NOT add a changeset — connector-only changes must not have one. Open the PR in the `public/` repo; the core repo bumps the submodule pointer after merge.)

- [ ] **Step 5: Manual verification note**

Record in the PR: assign a Linear-backed thread to a teammate in Plot → the Linear issue's assignee updates (resolved by email); unassign → Linear assignee clears. Failures are logged and reconciled on next sync.

---

# Phase 3 — Flutter widgets

### Task 10: `ThreadAssignee` reusable widget + `pickThreadAssignee`

**Files:**
- Create: `apps/plot/lib/widget/thread_assignee.dart`
- Modify: `apps/plot/lib/store/link.dart` (add `Link.getForConnection`)

- [ ] **Step 1: Add `Link.getForConnection` (connection-scoped links for the picker sort)**

In `link.dart`, mirror the row→`Link` mapping used by `Link.watchForThread`:

```dart
  /// All non-archived links created by [connectionId] (a twist_instance id).
  /// Used to rank likely assignees within a connection.
  static Future<List<Link>> getForConnection(ActorId connectionId) async {
    final rows = await (Store.get.select(Store.get.links)
          ..where((l) => l.createdBy.equalsValue(connectionId))
          ..where((l) => l.archivedAt.isNull()))
        .get();
    return rows.map(Link.new).toList();
  }
```

(Use the exact `Link` constructor / row-wrapper that `Link.watchForThread` uses — match its `.map(...)`. If `createdBy`/`archivedAt` column getters differ, use the names from the `Links` table in `link.dart`.)

- [ ] **Step 2: Write `ThreadAssignee` + `pickThreadAssignee`**

`thread_assignee.dart`:

```dart
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart' hide Link;

/// Reusable thread-level assignee control. Reads `thread.assigneeId`.
/// - Assigned: clickable single-avatar group (hover-highlight border).
/// - Unassigned: an "Assign" icon (only when [showWhenUnassigned]).
/// Display-only (no tap) when the thread is read-only.
class ThreadAssignee extends HookWidget {
  const ThreadAssignee({
    required this.thread,
    this.showWhenUnassigned = false,
    this.tooltipBelow = false,
    super.key,
  });

  final Thread thread;
  final bool showWhenUnassigned;
  final bool tooltipBelow;

  @override
  Widget build(BuildContext context) {
    final assigneeId = thread.assigneeId;
    final readOnly = thread.isReadOnly;

    final assigneeSnapshot = useFuture(
      useMemoized(() async {
        if (assigneeId == null) return null;
        try {
          return await Actor.getOne(assigneeId);
        } catch (_) {
          return null;
        }
      }, [assigneeId?.toString(), thread.id]),
    );
    final assignee = assigneeSnapshot.data ??
        (assigneeId != null ? Actor.fromCache(assigneeId) : null);

    final iconContentStyle =
        context.theme.buttonStyles.ghost.md.iconContentStyle;
    final iconPadding = iconContentStyle.padding.resolve(TextDirection.ltr);
    final iconSize = context.theme.iconSizes.base;
    final avatarSize = iconSize + iconPadding.top + iconPadding.bottom;

    final isHovered = useState(false);
    final iconColor =
        isHovered.value ? context.colour.foreground : context.colour.muted;

    if (assignee == null && !showWhenUnassigned) {
      return const SizedBox.shrink();
    }

    final Widget child;
    if (assignee != null) {
      child = AvatarGroup(
        actors: [assignee],
        totalCount: 1,
        size: avatarSize,
        scheduleContacts: null,
        tooltipBelow: tooltipBelow,
        clickable: !readOnly,
      );
    } else {
      child = SizedBox(
        width: iconSize,
        height: iconSize,
        child: Center(
          child: FaIcon(PlotIcon.assignAdd, size: iconSize, color: iconColor),
        ),
      );
    }

    // Read-only: show the avatar but do not allow changing it.
    if (readOnly) {
      return assignee != null ? child : const SizedBox.shrink();
    }

    final button = FButton.icon(
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(999)),
          ),
        ]),
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(horizontal: iconPadding.left),
          ),
          constraints: BoxConstraints(
            minHeight: iconContentStyle.constraints.minHeight,
          ),
        ),
      ),
      variant: FButtonVariant.ghost,
      onPress: () => pickThreadAssignee(context, thread),
      child: child,
    );

    if (assignee != null) return button;

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor:
            tooltipBelow ? Alignment.bottomCenter : Alignment.topCenter,
        tipBuilder: (context, controller) => const Text('Assign'),
        child: button,
      ),
    );
  }
}

/// Selection option for the assignee picker — equality by actor id.
class _AssigneeOption {
  const _AssigneeOption(this.id, this.name, this.email);
  final ActorId? id;
  final String name;
  final String? email;
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _AssigneeOption && id == other.id;
  @override
  int get hashCode => id.hashCode;
}

/// Opens the thread-level assignee picker. Writes the primary
/// assignment-capable link's assignee for connector threads (which the mirror
/// trigger reflects onto the thread); otherwise writes thread.assigneeId.
Future<void> pickThreadAssignee(BuildContext context, Thread thread) async {
  final links = await Link.getForThread(thread.id);
  final primaryLink = Thread.resolvePrimaryAssignmentLink(links);
  final currentId = primaryLink?.assigneeId ?? thread.assigneeId;
  final connectionId = primaryLink?.createdBy;

  // Connection-aware ranking: assignees on other links in this connection
  // first, then link authors in this connection, then everyone else. Plot-only
  // threads (no connection) fall back to thread participants then alphabetical.
  final rank = <String, int>{};
  if (connectionId != null) {
    final connLinks = await Link.getForConnection(connectionId);
    for (final l in connLinks) {
      final a = l.assigneeId?.toString();
      if (a != null) rank[a] = (rank[a] ?? 0) < 2 ? 2 : rank[a]!;
    }
    for (final l in connLinks) {
      final au = l.authorId?.toString();
      if (au != null) rank.putIfAbsent(au, () => 1);
    }
  } else {
    for (final c in thread.contacts) {
      rank[ActorId.fromUuid(c).toString()] = 1;
    }
  }

  final result = await SelectModal.open<_AssigneeOption>(
    context,
    items: (search) async {
      final actors = await Actor.get(
        search: search,
        types: [ActorType.user, ActorType.contact],
        limit: 50,
        inviteable: true,
        primary: true,
      );
      actors.sort((a, b) {
        // Current assignee first, then ranked, then self, then by name.
        final aCur = a.id == currentId ? 1 : 0;
        final bCur = b.id == currentId ? 1 : 0;
        if (aCur != bCur) return bCur - aCur;
        final ar = rank[a.id.toString()] ?? 0;
        final br = rank[b.id.toString()] ?? 0;
        if (ar != br) return br - ar;
        if (a.self != b.self) return a.self ? -1 : 1;
        return a.nameOrEmail.toLowerCase().compareTo(b.nameOrEmail.toLowerCase());
      });
      return [
        SelectGroup(
          items: [
            if (currentId != null) const _AssigneeOption(null, 'Unassign', null),
            ...actors.map((a) => _AssigneeOption(a.id, a.nameOrEmail, a.email)),
          ],
        ),
      ];
    },
    itemBuilder: (option, _) {
      final isCurrent = option.id != null && option.id == currentId;
      return ListTile(
        // Current assignee shown by colour + weight, not a checkmark.
        title: option.name,
        titleColor: isCurrent ? context.theme.colors.primary : null,
        titleWeight: isCurrent ? FontWeight.w600 : null,
        subtitle: (option.id != null &&
                option.email != null &&
                option.email != option.name)
            ? option.email
            : null,
        disableInternalHover: true,
      );
    },
    selectedValue: currentId != null
        ? _AssigneeOption(currentId, '', null)
        : null,
    prompt: 'Assign to',
  );

  if (!result.present || !context.mounted) return;
  final newId = result.value.id;
  if (newId == currentId) return;
  if (primaryLink != null) {
    await Link.updateAssignee(primaryLink, newId);
  } else {
    await Thread.updateAssignee(thread, newId);
  }
}
```

(If `ListTile` lacks `titleColor`/`titleWeight`, match the current-assignee styling using whatever the `ListTile` in `link_assignee_picker.dart` / the design system exposes — the requirement is "colour + weight, no checkmark." Check `lib/widget/`'s `ListTile` API and use its equivalents. `Link.getForThread` and `Link.authorId` already exist; confirm `authorId` getter name in `link.dart`.)

- [ ] **Step 3: Analyze**

```bash
cd apps/plot && flutter analyze lib/widget/thread_assignee.dart lib/store/link.dart
```
Expected: clean (fix any API-name mismatches surfaced — e.g. `ListTile` props, `Link` row mapping).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/thread_assignee.dart apps/plot/lib/store/link.dart apps/plot/lib/store/*.g.dart
git commit -m "feat(app): ThreadAssignee widget + connection-aware assignee picker"
```

---

### Task 11: `ThreadSharing` compact sharing widget

**Files:**
- Create: `apps/plot/lib/widget/thread_sharing.dart`

- [ ] **Step 1: Write `ThreadSharing`**

Renders `userPlus` (no recipients) or `users` + count; routes per `SharingModel` exactly as `SharedCommandButton`'s sharing branch did.

```dart
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart' hide Link;

/// Compact thread sharing control for the thread-page header.
/// - Not shared: `userPlus` icon. - Shared: `users` icon + recipient count.
/// Tap → editable share modal (thread model) or read-only participants
/// (message/channel). Hidden entirely for the `none` sharing model.
class ThreadSharing extends HookWidget {
  const ThreadSharing({required this.thread, this.tooltipBelow = false, super.key});

  final Thread thread;
  final bool tooltipBelow;

  @override
  Widget build(BuildContext context) {
    final linksSnapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(thread.id), [thread.id]),
    );
    final links = linksSnapshot.data ?? const <Link>[];
    final sharingModel = Thread.resolveSharingModel(links);
    if (sharingModel == SharingModel.none) return const SizedBox.shrink();

    final command = PickThreadShared(thread);
    final count = command.sharedTotalCount;
    final shared = count > 0;

    final isHovered = useState(false);
    final iconColor =
        isHovered.value ? context.colour.foreground : context.colour.muted;
    final iconSize = context.theme.iconSizes.base;

    final Widget child = shared
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FaIcon(PlotIcon.shared, size: iconSize, color: iconColor),
              SizedBox(width: context.theme.spacing.xs),
              Text('$count',
                  style: TextStyle(
                      color: iconColor,
                      fontSize: context.theme.typography.sm.fontSize,
                      height: 1)),
            ],
          )
        : FaIcon(PlotIcon.share, size: iconSize, color: iconColor);

    void open() {
      if (sharingModel == SharingModel.thread) {
        context.run(command);
      } else {
        context.run(PickThreadParticipants(thread));
      }
    }

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor:
            tooltipBelow ? Alignment.bottomCenter : Alignment.topCenter,
        tipBuilder: (context, controller) =>
            Text(shared ? 'People on this thread' : 'Share'),
        child: FButton.icon(
          variant: FButtonVariant.ghost,
          onPress: open,
          child: child,
        ),
      ),
    );
  }
}
```

(`PlotIcon.share` = userPlus, `PlotIcon.shared` = users — confirmed in `widget/icon.dart`. `context.run`, `useStream`, `PickThreadShared`, `PickThreadParticipants` are all already used in `widget/thread.dart`.)

- [ ] **Step 2: Analyze**

```bash
cd apps/plot && flutter analyze lib/widget/thread_sharing.dart
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/thread_sharing.dart
git commit -m "feat(app): ThreadSharing compact header widget"
```

---

### Task 12: `AssignThread` command

**Files:**
- Modify: `apps/plot/lib/command/thread.dart`

- [ ] **Step 1: Add the command**

Place near `PickThreadShared` (~line 2337). It opens the assignee picker.

```dart
/// Assign / reassign a thread. Surfaced as a hover command (before More) for
/// unassigned threads, and in the More menu for keyboard/menu access.
class AssignThread extends Command {
  AssignThread(this.thread)
      : super(
          title: thread.assigneeId != null ? 'Reassign' : 'Assign',
          icon: PlotIcon.assignAdd,
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await pickThreadAssignee(context, thread);
    return const CommandDone();
  }
}
```

(Add the import for `pickThreadAssignee` from `package:plot/widget/thread_assignee.dart`. Confirm `CommandReturn`/`CommandDone`/`EventAction.updated` match the conventions used by neighbouring commands in this file.)

- [ ] **Step 2: Add `AssignThread` to the More menu pool**

In `threadCommands` (the list returned ~line 3590), add `AssignThread(thread)` next to `PickThreadShared(thread)` so it appears in the More menu (skip for read-only — it's inside the non-read-only branch already):

```dart
    if (sharingModel == SharingModel.thread) PickThreadShared(thread),
    AssignThread(thread),
```

- [ ] **Step 3: Analyze**

```bash
cd apps/plot && flutter analyze lib/command/thread.dart
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "feat(app): AssignThread command"
```

---

### Task 13: Thread-page header — sharing + assign

**Files:**
- Modify: `apps/plot/lib/page/thread.dart:1375-1378`

- [ ] **Step 1: Replace the header end group**

Add the imports for `ThreadSharing` and `ThreadAssignee`. Replace lines 1375-1378:

```dart
    final endGroup = <Widget>[
      if (!readOnly) ThreadSharing(thread: thread, tooltipBelow: true),
      if (!readOnly)
        ThreadAssignee(
          thread: thread,
          showWhenUnassigned: true,
          tooltipBelow: true,
        ),
      Button.icon(_buildThreadMenuCommand(thread), tooltipBelow: true),
    ];
```

- [ ] **Step 2: Analyze**

```bash
cd apps/plot && flutter analyze lib/page/thread.dart
```
Expected: clean (the old `SharedCommandButton` reference here is gone; it's removed entirely in Task 14).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/thread.dart
git commit -m "feat(app): header shows sharing + assign widgets"
```

---

### Task 14: Thread row — persistent avatar + Assign hover command; delete `SharedCommandButton`

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart` (`ThreadCommands` ~906-1024; delete `SharedCommandButton` 1027-1282)

- [ ] **Step 1: Filter `AssignThread` out of the auto hover pool**

In `ThreadCommands.build`, extend the `hoverCommands` `where` (lines 928-933) to also exclude `AssignThread` (so it's placed explicitly, like `PickThreadShared`):

```dart
      ...rawHoverCommands.where(
        (cmd) =>
            cmd is! PickScheduleThread &&
            cmd is! PickThreadShared &&
            cmd is! AssignThread &&
            cmd is! EditThread,
      ),
```

- [ ] **Step 2: Replace the assignment gate + trailing widget**

Replace the `hasAssignment` block (lines 967-974) with an `isAssigned` check, and add the explicit Assign hover command before the More button. First, change the trailing widget (line 1012-1014):

```dart
        // Persistent thread-level assignee avatar (any assigned thread).
        if (thread.assigneeId != null) ThreadAssignee(thread: activity),
```

Then add the hover Assign command. In the `if (showCommands)` branch (lines 977-994), insert before the `ShowThreadCommands` (More) button:

```dart
      allButtons = [
        ...threadCommandButtons.take(5),
        Button.icon(MuteSimilarThreads(activity)),
        if (activity.assigneeId == null && !activity.isReadOnly)
          Button.icon(AssignThread(activity)),
        Button.icon(
          CommandWrapper(
            ShowThreadCommands(activity),
            icon: Value(PlotIcon.more),
          ),
        ),
      ];
```

(Note `activity` is the field name for the thread inside `ThreadCommands`; the trailing-widget snippet uses `activity` too — keep it consistent. Remove the now-unused `hasAssignment` local and its `Thread.resolvePrimaryAssignmentLink` call.)

- [ ] **Step 3: Delete `SharedCommandButton`**

Remove the entire `SharedCommandButton` class (lines 1027-1282) and its leading doc comment. Verify it has no other references:

```bash
cd apps/plot && grep -rn "SharedCommandButton" lib/ ; echo "exit: $?"
```
Expected: no matches (only the two call sites existed; both replaced).

- [ ] **Step 4: Import the new widgets**

Add imports for `package:plot/widget/thread_assignee.dart` and (if not already) ensure `AssignThread` is imported in `thread.dart`.

- [ ] **Step 5: Analyze the whole app**

`SharedCommandButton` removal + new widgets touch shared code, so analyze broadly:

```bash
cd apps/plot && flutter analyze lib/widget/thread.dart lib/page/thread.dart lib/command/thread.dart lib/widget/thread_assignee.dart lib/widget/thread_sharing.dart
```
Expected: clean. (CI lint is `flutter analyze --no-fatal-infos`; infos are tolerated, errors are not.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/thread.dart
git commit -m "feat(app): row shows assignee avatar + Assign hover command; drop SharedCommandButton"
```

---

# Phase 4 — Assignee search filter

### Task 15: Assignee filter dimension end-to-end

**Files:**
- Modify: `apps/plot/lib/state/priority_state.dart` (~line 187)
- Modify: `apps/plot/lib/state/priority.dart` (`_hasActiveFilter` line 847; `_subscribeAllTabHead` ~885-912)
- Modify: `apps/plot/lib/store/thread.dart` (`_buildFeedFilter` ~2410; `watchAllTabHead` signature)
- Modify: `apps/plot/lib/command/filter.dart` (new `ToggleAssigneeFilter`)
- Modify: `apps/plot/lib/widget/unified_header.dart` (`buildFilters` ~755; active chips ~805)

- [ ] **Step 1: Add the state field**

In `priority_state.dart`, alongside `filter`/`iconFilter` (~line 187) add:

```dart
  final List<ActorId> assigneeFilter;
```

Add it to the constructor (default `const []`), `copyWith`, and `props`/equality the same way `iconFilter` is wired (follow each occurrence of `iconFilter` in this file and add a parallel `assigneeFilter`).

- [ ] **Step 2: Include it in `_hasActiveFilter`**

`priority.dart` line 847-850:

```dart
  bool get _hasActiveFilter =>
      state.filter.isNotEmpty ||
      state.reactionFilter.isNotEmpty ||
      state.iconFilter.isNotEmpty ||
      state.assigneeFilter.isNotEmpty;
```

- [ ] **Step 3: Pass it to the flat-mode query**

In `_subscribeAllTabHead` (priority.dart), add after the `iconFilter` local (line 888):

```dart
    final assigneeFilter =
        state.assigneeFilter.isNotEmpty ? state.assigneeFilter : null;
```

And pass it to `Thread.watchAllTabHead(...)` (line 905-913):

```dart
        iconFilter: iconFilter,
        assigneeFilter: assigneeFilter,
        search: search,
```

- [ ] **Step 4: Thread query — signature + predicate**

In `thread.dart`, add `List<ActorId>? assigneeFilter` to `watchAllTabHead`'s named params and thread it through to wherever it calls `_buildFeedFilter` (mirror how `iconFilter` is passed). Then in `_buildFeedFilter` (after the icon-filter block ~line 2432):

```dart
    // Assignee filter — match thread-level assignee_id.
    if (assigneeFilter != null && assigneeFilter.isNotEmpty) {
      final placeholders = assigneeFilter.map((_) => '?').join(',');
      wheres.add('a.assignee_id IN ($placeholders)');
      for (final id in assigneeFilter) {
        variables.add(Variable.withBlob(const ActorIdConverter().toSql(id)));
      }
    }
```

Add `List<ActorId>? assigneeFilter` to `_buildFeedFilter`'s parameters too (alongside `iconFilter`).

- [ ] **Step 5: `ToggleAssigneeFilter` command**

In `filter.dart`, mirror `ToggleIconFilter`:

```dart
class ToggleAssigneeFilter extends Command {
  ToggleAssigneeFilter._({required this.assigneeId, required this.label, super.on})
      : super(title: label, icon: PlotIcon.assignAdd);

  factory ToggleAssigneeFilter(ActorId assigneeId,
      {required String label, required BuildContext context}) {
    final bloc = context.read<PriorityBloc>();
    final active = bloc.state.assigneeFilter.contains(assigneeId);
    return ToggleAssigneeFilter._(assigneeId: assigneeId, label: label, on: active);
  }

  final ActorId assigneeId;
  final String label;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final bloc = context.read<PriorityBloc>();
    final next = List<ActorId>.from(bloc.state.assigneeFilter);
    next.contains(assigneeId) ? next.remove(assigneeId) : next.add(assigneeId);
    bloc.updateAssigneeFilter(next); // add this setter on PriorityBloc, mirroring updateFilter
    return const CommandDone();
  }
}
```

Add `void updateAssigneeFilter(List<ActorId> f)` to `PriorityBloc` mirroring the existing `updateFilter` (emit `state.copyWith(assigneeFilter: f)` then re-subscribe the feed).

- [ ] **Step 6: Surface in the filter picker + active chips**

In `unified_header.dart` `buildFilters` (~line 755-769), append assignee options. Compute candidate assignees from the visible scope (distinct `state.actors` already loaded, plus a self/"Assigned to me" entry). Minimal first cut — offer the distinct assignees present on the priority's threads (from `state.actors`) :

```dart
        ...state.actors
            .where((a) => /* appears as an assignee in scope */ true)
            .map((a) => ToggleAssigneeFilter(a.id, label: a.nameOrEmail, context: ctx)),
```

And add active assignee chips in the `suffixBuilder` `activeFilters` list (~line 805):

```dart
                    for (final id in state.assigneeFilter)
                      ToggleAssigneeFilter(
                        id,
                        label: Actor.fromCache(id)?.nameOrEmail ?? 'Assignee',
                        context: context,
                      ),
```

(Keep the candidate set simple for v1: assignees present on visible threads. "Assigned to me" / "Unassigned" quick entries can be added the same way — `Unassigned` is a sentinel handled by filtering `a.assignee_id IS NULL`; defer if it complicates the chip model.)

- [ ] **Step 7: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/priority_state.dart lib/state/priority.dart lib/store/thread.dart lib/command/filter.dart lib/widget/unified_header.dart
```
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/state/priority_state.dart apps/plot/lib/state/priority.dart apps/plot/lib/store/thread.dart apps/plot/lib/command/filter.dart apps/plot/lib/widget/unified_header.dart apps/plot/lib/store/*.g.dart
git commit -m "feat(app): assignee search filter"
```

---

# Phase 5 — Finalization

### Task 16: Runtime verification + docs + finalize

- [ ] **Step 1: Run the app and smoke-test (run-app skill)**

Verify, in order: (a) assign a Plot-only thread from the header "Assign" → avatar appears in header + row; (b) reassign via the picker (current assignee shown by colour+weight, Unassign present, no checkmark); (c) unassigned thread row shows "Assign" on hover before More; (d) assign a Linear thread → avatar reflects it and the picker ranks connection people near the top; (e) assignee search filter narrows the list. Capture runtime errors with `mcp__dart-mcp__get_runtime_errors` (expect none).

- [ ] **Step 2: Docs**

Add a bullet to the top of `docs/updates.md`:

```markdown
- You can now assign any thread to someone — yourself or a teammate — from the thread header or the row's hover actions. For threads tied to a connected tool that tracks an assignee (like a Linear issue), changing the assignee in Plot updates it there too, and changes made in the tool flow back into Plot. You can also filter your list by assignee.
```

Update `docs/features.md` with a short "Thread assignment" capability line under the relevant section.

- [ ] **Step 3: Finalize**

Run the `/finalize` checklist: `flutter analyze` (app), `pnpm lint` in changed TS packages, `pnpm --filter @plotday/db run lint`, confirm no new `catch` blocks swallow unexpected errors without capture, and confirm the `public/` Linear change is a separate PR with no changeset.

- [ ] **Step 4: Commit docs**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: thread assignment"
```

---

## Self-Review checklist (completed by plan author)

- **Spec coverage:** thread.assignee_id (T2,T3,T8) · external-wins mirror (T6) · sticky supports_assignee (T5) · backfill (T7) · Plot-only write (T8,T10) · connector write-back (T9) · ThreadAssignee reusable widget + read-only display-only (T10) · ThreadSharing userPlus/users+count (T11) · header order (T13) · row persistent avatar + Assign-before-More hover command (T14) · flat picker, Unassign, current-by-colour+weight, connection-aware sort (T10) · assignee search filter (T15) · docs/finalize (T16). All spec sections map to a task.
- **Known follow-ups flagged in-task (not placeholders):** exact `Link` row→model mapping in `getForConnection` (mirror `watchForThread`); `ListTile` colour/weight prop names; the filter candidate-set query (v1 = assignees in scope; "Unassigned"/"Assigned to me" sentinels deferred). Each names the concrete file/pattern to follow.
- **Type consistency:** `assigneeId`/`assignee_id` (ActorId ↔ uuid), `supports_assignee` (bool), `ThreadAssignee`/`ThreadSharing`/`AssignThread`/`pickThreadAssignee`/`Thread.updateAssignee`/`Link.getForConnection`/`recompute_thread_assignee` used consistently across tasks.
