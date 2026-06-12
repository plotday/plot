# Onboarding threads: markdown-authored source → generated migrations

**Date:** 2026-06-12
**Status:** Design approved, pending spec review

## Problem

The content of Plot's onboarding threads exists **only inside database
migrations** as hardcoded SQL. There is no canonical, editable source. Today the
content is spread across:

- The seven **global** onboarding threads (`welcome`, `priorities`,
  `connections`, `getting-around`, `twists`, `notifications`, `clean-up`) — first
  created by `libs/db/migrations/20260414233029_global_onboarding_threads.sql`
  with `INSERT INTO thread/note`, and edited by a chain of later ad-hoc
  `UPDATE` migrations.
- The **per-user welcome** thread (`welcome-user` + notes `welcome`,
  `core-trial`), seeded per signup by the
  `public.activate_invited_user(p_user_id)` function in
  `libs/db/schema/60-functions/activate_invited_user.sql`.
- The **initial per-user state** for the global threads (which land in Doing,
  their Updates ordering, their scheduled date, and which note is an actionable
  to-do), encoded as hardcoded `CASE` tables in two trigger functions:
  `file_onboarding_schedules()`
  (`libs/db/schema/95-triggers/25-onboarding_schedules.sql`) and
  `file_onboarding_todos()` (`.../26-onboarding_todos.sql`).

Editing this content means hand-writing SQL `UPDATE`s, matching rows by fragile
criteria (titles, ordinal `ROW_NUMBER` over `source_created_at`). The original
global-thread migration even used a bare `DELETE ... WHERE key IN (...)` then
re-`INSERT`, which is the sync-stranding anti-pattern AGENTS.md warns against.

## Goal

A canonical markdown source for onboarding threads plus a generator script that
emits the migrations needed to reconcile the database to that source. Authors
must be able to:

- **Re-title** a thread (edit frontmatter).
- **Add** a thread (add a markdown file).
- **Archive** a thread (delete the markdown file → reconcile archives it,
  never `DELETE`s).
- Edit / add / remove / reorder **notes** within a thread.
- Set **initial per-user state** (to-do/active, optional importance, optional
  scheduled date offset) for global threads, and the per-user welcome thread's
  content + state.

All matching is by **stable keys**, never string matching on titles.

## Scope decisions (from brainstorming)

1. **Both global and per-user** onboarding threads are markdown-authored, but
   with different blast radius:
   - **Global thread content** (title, preview, note bodies/keys) is a shared
     row → editing it updates the rows **all users** see.
   - **Per-user content + per-user state** (the `welcome-user` thread, and the
     initial `thread_state` / to-do tags applied to global threads at join) is
     applied **once at signup** → editing it affects **new users only**;
     existing users' rows are left untouched.

2. **Reconcile model** for archival: markdown is desired state. A key present in
   the committed snapshot but absent from current markdown is **archived**
   (`archived_at = now()`), never deleted. No explicit archive flag.

3. **Custom data-migration generator** (not a schema-resident seed function).
   The script writes a timestamped migration directly into
   `libs/db/migrations/` and runs `atlas migrate hash`.

4. **Visibility (groups / contacts / topic) is hardcoded in the generator**, not
   authored per file:
   - Global threads: groups = `[Everyone, Plot Team]`, topic = the current
     Using-Plot / onboarding topic.
   - Per-user welcome: groups = `[Plot Team]`, contacts = `[the user]`.
   These resolve at migration runtime via the same deterministic lookups the
   current code uses (the `auto_maintained` "Everyone" topic, the Plot Team
   auto-group), so no per-environment UUIDs are written into files.

## Source layout

```
libs/db/onboarding/
  global/                    # the 7 shared threads (all users see these)
    01-welcome.md
    02-priorities.md
    03-connections.md
    04-getting-around.md
    05-twists.md
    06-notifications.md
    07-clean-up.md
  per-user/
    01-welcome-user.md       # seeded per-signup by activate_invited_user()
  .snapshot.json             # checked-in compiled state — registry of managed
                             # keys + content hashes; basis for change detection
                             # and archive-on-removal
```

### File format

```markdown
---
key: priorities
title: Create your initial focuses
preview: Focuses are contexts for focus, often roles and goals...
state:
  active: true        # → thread_state.active (lands in Doing / actionable)
  importance: 90      # OPTIONAL → Updates ordering (omit if not needed)
  dateOffset: 0       # OPTIONAL → thread_state."on" daterange start =
                      #   join date + N days; omit/0 ⇒ always-on (1970→∞)
---

## note: intro
Focuses are contexts for focus, often roles (like VP Marketing) and goals...

## note: todo            # the `todo`-keyed note is the actionable one →
                         #   Tag.Todo applied at join by file_onboarding_todos
Create your first focus — for example, **Work** or **Personal**.
```

Rules:

- **Thread order** is derived from the **numeric filename prefix**
  (`01-`, `02-`, …). Not authored in frontmatter. Drives `thread_state."order"`
  (relative ordering within a date group) and note/thread sequencing.
- **Note order** is the section order within the file. Drives note
  `source_created_at` offsets.
- The `## note: <key>` heading carries the **stable note key**. The body below
  (until the next `## note:` or EOF) is the markdown content.
- `state` is optional. Within it, `active` defaults to `false`, `importance` and
  `dateOffset` are optional. The `todo` note key (not a flag) marks the
  actionable note.
- `per-user/01-welcome-user.md` owns **content + state only** (title, preview,
  note bodies/keys, `state`). All structural plumbing in `activate_invited_user`
  — system instance id, Plot Team group resolution, contacts array, filing,
  `thread_priority` insert — stays in the function template and is not authored
  in markdown.

## Generator: `pnpm gen-onboarding`

New script `scripts/gen-onboarding-migration.ts`, wired as a `pnpm` script in
`libs/db/package.json` (alongside `gen-migration`).

### Run flow

1. Parse `global/*.md` and `per-user/*.md` into an in-memory model. Compute
   per-thread and per-note content hashes and the managed key-set.
2. Load `.snapshot.json` (last-generated keys + hashes). Diff current model
   against it.
3. **No diff → exit 0, no migration written.** Print "onboarding up to date".
4. **Diff →** write **one** timestamped migration
   `libs/db/migrations/<ts>_onboarding_<slug>.sql` containing the parts below,
   run `atlas migrate hash --dir file://libs/db/migrations`, and rewrite
   `.snapshot.json`. Print a summary (threads/notes added·updated·archived,
   functions regenerated).

### `--check` mode

`pnpm gen-onboarding --check` recompiles the markdown and compares to the
committed `.snapshot.json` without writing anything; exits non-zero if they
differ. Wired into the `db:lint` CI step (mirrors `gen-types --check`) so nobody
can edit the markdown without regenerating and committing the migration.

## Generated migration contents

A single migration, written so it is **idempotent** and **Atlas-robust** (early
`RETURN` when the environment has no users / no Plot system rows yet, matching
the existing global migration's guards).

### 1. Global thread + note content reconcile (affects all users)

- Resolve author (`kris@plot.day` → fallback any user) and the hardcoded
  visibility targets (Everyone topic, Plot Team group, Using-Plot/onboarding
  topic) via the same lookups used today. **Thread authorship and columns are
  preserved exactly as the current rows** — no `twist_id`/attribution change, to
  avoid altering filing or visibility behavior.
- **Threads** — upsert by `key`: `SELECT id` by key (scoped to onboarding via
  the snapshot key-registry + the Everyone-topic guard); if found `UPDATE`
  title/preview, else `INSERT`. Capture `thread_id` in a `DO $$` block.
- **Notes** — upsert by `(thread_id, key)` using the existing partial unique
  index `note_thread_link_key_unique (thread_id, link_id, key)` where
  `key IS NOT NULL`. Set `source_created_at` from section order. `content` from
  the section body.
- **Removed keys** (in snapshot, absent now) — `UPDATE thread SET
  archived_at = now()` / `UPDATE note SET archived_at = now()`. **Never
  `DELETE`** (sync-safe, per AGENTS.md "Removing Rows from Synced Tables").

### 2. Regenerated per-user-state functions (affects new users only)

Emitted as `CREATE OR REPLACE FUNCTION`, and the corresponding **schema files
are rewritten in the same run** so `pnpm diff-schema-migrations` stays clean:

- **`file_onboarding_schedules()`** (`95-triggers/25-onboarding_schedules.sql`)
  — its `CASE v_thread_key` table is rebuilt from each global thread's `state`
  frontmatter: `active`, `importance` (optional), and the `"on"` daterange from
  `dateOffset` (optional). `"order"` derives from filename prefix. The thread-key
  `IN (...)` guard list is rebuilt from the managed global keys.
- **`file_onboarding_todos()`** (`95-triggers/26-onboarding_todos.sql`) — its
  thread-key `IN (...)` list is rebuilt from the global threads that contain a
  `## note: todo` section. (Matching on `note.key = 'todo'` is unchanged.)
- Both keep their existing `current_setting('plot.skip_onboarding_*')` escape
  hatches and `ON CONFLICT DO NOTHING` semantics, so regeneration never
  resurrects or overwrites an existing user's state.

### 3. Regenerated per-user welcome (affects new users only)

- The marker-delimited region of `activate_invited_user()`
  (`60-functions/activate_invited_user.sql`) is rewritten from
  `per-user/01-welcome-user.md`: thread title/preview, note bodies/keys, and
  `thread_state` values (importance/order/`on`) from its `state` block. The
  surrounding plumbing is left intact. Emitted as `CREATE OR REPLACE FUNCTION`
  into the same migration.

## One-time prerequisite: migration-0 (note-key backfill)

Existing global notes have **no `key`**. Before the generator's key-based
matching can work, a single hand-reviewed migration assigns keys to the existing
note rows of the seven global threads by matching on
`(thread.key, ROW_NUMBER() OVER (PARTITION BY thread ORDER BY source_created_at))`
to the markdown section order, validated against expected per-thread note counts
(abort if counts disagree). This is the **only** ordinal-match step; it runs
once, after which all matching is key-based. (Per-user notes already have keys
`welcome` / `core-trial`.)

The initial `global/*.md` and `per-user/*.md` files are authored to **exactly
reproduce the current production content and state** (titles, previews, note
bodies, the `CASE`-table active/importance/dateOffset values, and which note is
`todo`), so the first `pnpm gen-onboarding` after migration-0 produces an
empty/no-op diff — confirming round-trip fidelity before any real edit.

## Identity & sync-safety summary

| Entity | Identity | On removal |
|---|---|---|
| Global thread | `key` (scoped via snapshot registry + Everyone-topic guard) | `archived_at = now()` |
| Global note | `(thread_id, key)` | `archived_at = now()` |
| Per-user welcome thread/notes | regenerated in function body | n/a (new users only) |
| Per-user state (schedules/todos) | regenerated `CASE`/key-list | n/a (new users only) |

## Testing

- **Unit:** markdown→model compiler (frontmatter, section parsing, order
  derivation from filename, optional-field defaults); SQL emitter golden-file
  snapshots for a fixture set (content reconcile + all three regenerated
  functions).
- **Integration (throwaway DB):**
  - Apply a generated migration **twice** → second run no-ops (idempotency).
  - Retitle fixture → `UPDATE` only; verify content changes.
  - Remove fixture → `archived_at` set, no `DELETE`.
  - Verify regenerated `file_onboarding_schedules`/`file_onboarding_todos`
    produce the expected `thread_state` / `note_tag` for a freshly activated
    user, and that an already-activated user's state is unchanged.
- **Round-trip:** after migration-0 + authoring the initial files,
  `pnpm gen-onboarding` produces no migration (no-op diff).

## Authoring workflow (end state)

| Task | Action | Effect |
|---|---|---|
| Re-title a thread | edit frontmatter `title:` | `UPDATE` (all users) |
| Edit a note | edit `## note:` body | `UPDATE` (all users) |
| Add a thread | add `NN-key.md` | `INSERT` (all users) + seeded state for new users |
| Archive a thread | delete the file | `archived_at` set (all users) |
| Reorder threads | renumber filename prefixes | `order` updated for new users |
| Reorder notes | reorder sections | `source_created_at` updated |
| Change to-do/scheduled/importance | edit `state:` | new users only |
| Change per-user welcome | edit `per-user/01-welcome-user.md` | new users only |

Then: `pnpm gen-onboarding` → review the generated migration →
`pnpm apply-migrations` → commit markdown + migration + `.snapshot.json` +
regenerated schema files together.

## Out of scope

- Backfilling per-user state changes onto existing users (deliberately
  new-users-only).
- Changing global-thread authorship/`twist_id` or visibility wiring beyond the
  hardcoded constants above.
- A UI for editing onboarding content (markdown files only).
