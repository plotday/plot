# Structured-Items Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the generic platform/SDK foundation for syncing *structured items* (checklists today, any product's subtask/checklist items later) as Plot **notes** with two-way completion + assignment: new `note` section/position columns, the matching Twister `Note`/`NewNote` fields, an `Actor.source` field, and runtime dispatch-time enrichment that hands a connector each assignee's external account id without a lookup call.

**Architecture:** A note becomes a "structured item" by carrying `section_*` (which group it belongs to) + `item_position` (order within the group) — additive nullable columns that sync to clients via `user.note`. For two-way **assignment**, the per-actor `note_tag` model already carries Todo/Done; the missing piece is letting a connector resolve a Plot assignee back to its external id. We add `Actor.source.accountId` to the SDK and have the runtime populate it at **dispatch time** from `contact_external_account` (scoped to the connector's `twist_instance_id`) — symmetric with the inbound `NewContact.source.accountId` connectors already set. No connector lookup call; no extra round-trip.

**Tech Stack:** PostgreSQL + Atlas migrations, `@plotday/twister` (workspace, public submodule), Cloudflare Workers (Kysely), vitest.

## Global Constraints

- **This is Plan 3 of the Trello effort** (spec Part 3, Layer 1). It is the prerequisite for **Plan 4** (Trello checklist sync). Spec: `docs/superpowers/specs/2026-06-25-trello-connector-design.md` (Part 3). Plans 1–2 (auth provider + connector core) are already on this branch.
- **Scope is server + SDK only.** The **Drift/Flutter client columns and the grouped checklist UI are deferred to Plan 5.** The data flows connector → `note` columns → `user.note` view → sync payload regardless; the client storing/rendering it is Plan-5 work. Do NOT touch `apps/plot/` in this plan.
- **⚠️ DATABASE HAZARD — read before any migration command.** The worktree DB is on **port 54330** (`.worktree-db` → `PORT="54330"`), but this session's `$DATABASE_URL` is **stale** (points at the main repo's `54322`). Running `pnpm gen-migration`/`apply-migrations`/`diff-schema-migrations` with the ambient env would **corrupt the main repo's DB**. EVERY migration command MUST override the URL:
  ```bash
  cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/libs/db   # or repo root
  source ../.worktree-db   # sets PORT (from libs/db, the file is one level up; from repo root: `source .worktree-db`)
  export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
  psql "$DATABASE_URL" -tAc "select inet_server_port();"   # sanity: connection works; NOT against 54322
  ```
  Subagents inherit the same stale env, so any migration dispatch must carry the explicit override.
- **Migration workflow** (per `libs/db/AGENTS.md`): schema files in `libs/db/schema/` are the source of truth; `pnpm gen-migration -- <name>` generates the timestamped migration (auto-updates `atlas.sum`); `pnpm apply-migrations` applies it AND regenerates `libs/db/src/types.ts` (commit it); `pnpm diff-schema-migrations` must show no diff afterward. Never hand-edit applied migrations.
- **Column names (exact):** `section_key text`, `section_label text`, `section_position text`, `item_position text` (all nullable; `text` for fractional-index ordering — lexicographic, insertion-stable). Twister fields: `sectionKey`, `sectionLabel`, `sectionPosition`, `itemPosition` (`string | null`). Actor field: `source: { accountId: string } | null`.
- **Twister changeset is REQUIRED** for the `public/twister/src/` changes (`@plotday/twister: minor`, summary starts with `Added:`).
- **`note` seq auto-bumps** on any UPDATE via the existing `update_seq_and_updated_at` trigger — new columns sync for free, no trigger work needed.
- **Error capture:** new `catch` for unexpected runtime errors → `tracker.captureException` / `postHog.captureException`. The enrichment query failing is unexpected (DB) → handle per the "never ignore DB errors" rule (use `safeQuery`/await + propagate, or log+degrade gracefully so a dispatch isn't lost).
- **Test command (workers/api):** `cd workers/api && pnpm vitest run <path>`. **Twister build:** `cd public/twister && pnpm build`.

---

### Task 1: DB migration — `note` section/item columns + `user.note` view

**Files:**
- Modify: `libs/db/schema/50-tables/25-note.sql` (add 4 columns)
- Modify: `libs/db/schema/90-user-schema/31-note.sql` (`user.note` view SELECT)
- Generated: `libs/db/migrations/<timestamp>_add_note_structured_item_fields.sql` + `atlas.sum`
- Regenerated: `libs/db/src/types.ts`

**Interfaces:**
- Produces: `note.section_key`, `note.section_label`, `note.section_position`, `note.item_position` (all `text` null), exposed in `user.note`.

> **Controller note:** this task is best run by the controller (or a subagent with the explicit `DATABASE_URL` override hammered in), because of the stale-`$DATABASE_URL` hazard above. There is no TDD test cycle for a DDL-only change — the gates are `apply-migrations` succeeding, `diff-schema-migrations` clean, and `types.ts` containing the new columns.

- [ ] **Step 1: Set the safe DATABASE_URL (every shell that runs a migration cmd)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
source .worktree-db
export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
psql "$DATABASE_URL" -tAc "select inet_server_port();"   # connection OK; must NOT be the main 54322 DB
```

- [ ] **Step 2: Add the 4 columns to the `note` table**

In `libs/db/schema/50-tables/25-note.sql`, add after `"canonical_source" text,` (and before `"embedding"`):
```sql
    "section_key" text,
    "section_label" text,
    "section_position" text,
    "item_position" text,
```
Optionally add a COMMENT documenting them as the generic structured-item grouping/ordering fields (a connector sets them; the app renders grouped/ordered later).

- [ ] **Step 3: Expose the 4 columns in `user.note`**

In `libs/db/schema/90-user-schema/31-note.sql`, in the SELECT, add after `n.merged_from_thread_id` (keep the existing trailing columns/commas correct):
```sql
    n.section_key,
    n.section_label,
    n.section_position,
    n.item_position,
```

- [ ] **Step 4: Generate + apply the migration (with the override)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm gen-migration -- add_note_structured_item_fields
pnpm apply-migrations          # applies + regenerates libs/db/src/types.ts (CI=false)
pnpm diff-schema-migrations    # MUST show no differences
```
Expected: a new migration file `ADD COLUMN section_key/section_label/section_position/item_position` (+ the `user.note` view CREATE OR REPLACE), apply succeeds, diff clean.

- [ ] **Step 5: Verify the columns + view**

```bash
psql "$DATABASE_URL" -tAc "select column_name from information_schema.columns where table_schema='public' and table_name='note' and column_name like '%section%' or column_name='item_position';"
psql "$DATABASE_URL" -tAc "select column_name from information_schema.columns where table_schema='user' and table_name='note' and (column_name like 'section%' or column_name='item_position');"
grep -n "section_key\|item_position" libs/db/src/types.ts | head
```
Expected: the 4 columns on `public.note` AND `user.note`; `types.ts` has them.

- [ ] **Step 6: Commit** (main repo)

```bash
git add libs/db/schema/50-tables/25-note.sql libs/db/schema/90-user-schema/31-note.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add note section/item structured-item columns"
```

---

### Task 2: Twister types — `Note`/`NewNote` fields + `Actor.source` + `tagActors` + changeset

**Files:**
- Modify: `public/twister/src/plot.ts` (`Note`, `Actor`)
- Create: `public/.changeset/structured-item-fields.md`

**Interfaces:**
- Produces (on `Note`, inherited into `NewNote` via `Partial<Omit<...>>`): `sectionKey: string | null`, `sectionLabel: string | null`, `sectionPosition: string | null`, `itemPosition: string | null`.
- Produces on `Note` only (runtime-dispatch enrichment, see Task 4): `tagActors: Record<ActorId, Actor>` — maps each actor id referenced in `tags` to its `Actor` (with `source` populated). Populated by the runtime on connector dispatch; `{}` otherwise.
- Produces on `Actor`: `source: { accountId: string } | null` — the actor's external account id for the connector receiving the dispatch (symmetric with `NewContact.source`).

- [ ] **Step 1: Add the structured-item fields to `Note`**

In `public/twister/src/plot.ts`, in the `Note` type (after `cta: Cta | null;`):
```typescript
  /** Group this note belongs to within its thread (e.g. a Trello checklist id). Null = ordinary note. */
  sectionKey: string | null;
  /** Display label for the group (e.g. the checklist name). */
  sectionLabel: string | null;
  /** Sort position of the group among the thread's groups (fractional index). */
  sectionPosition: string | null;
  /** Sort position of this item within its group (fractional index). */
  itemPosition: string | null;
  /**
   * Actors referenced by this note's `tags`, hydrated with `source.accountId`
   * for the connector receiving this dispatch. Populated by the runtime only on
   * connector dispatch (so a connector can resolve an assignee to its external
   * id without a lookup); `{}` elsewhere.
   */
  tagActors: Record<ActorId, Actor>;
```
(`NewNote` automatically gains `sectionKey`/`sectionLabel`/`sectionPosition`/`itemPosition` as optional via its `Partial<Omit<Note, ...>>`. `tagActors` is read-only output, so add it to the `NewNote` Omit list so connectors don't set it: in the `NewNote` `Omit<Note, "author" | "thread" | ... >` union, add `"tagActors"`.)

- [ ] **Step 2: Add `source` to `Actor`**

In the `Actor` type (after `name?: string | null;`):
```typescript
  /**
   * The actor's external account id for the connector receiving this object
   * (e.g. a Trello member id), or null if the actor has no linked account for
   * that connector. Populated by the runtime on dispatch — symmetric with
   * `NewContact.source.accountId` which connectors set on inbound sync.
   */
  source?: { accountId: string } | null;
```

- [ ] **Step 3: Add the changeset**

`public/.changeset/structured-item-fields.md`:
```markdown
---
"@plotday/twister": minor
---

Added: structured-item note fields (`sectionKey`, `sectionLabel`, `sectionPosition`, `itemPosition`), `Note.tagActors` (dispatch-time hydrated assignees), and `Actor.source.accountId` (external account id resolved at dispatch).
```

- [ ] **Step 4: Build twister + validate + refresh workspace**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/twister && pnpm build
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public && pnpm validate-changesets
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector && pnpm install
```
Expected: twister builds clean; changeset valid; workspace link updated. (`workers/api` may not fully typecheck until Tasks 3–4 consume the new fields — expected.)

- [ ] **Step 5: Commit** (submodule)

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public
git add twister/src/plot.ts .changeset/structured-item-fields.md
git commit -m "feat(twister): structured-item note fields + Actor.source + tagActors"
```

---

### Task 3: Runtime — write section fields in `createNote`; expose them on the dispatched/synced `Note`

**Files:**
- Modify: `workers/api/src/twist/tools/plot/note.ts` (`createNote` dbNote build)
- Modify: `workers/api/src/twist/tools/integrations.ts` (`buildNoteAndThread` — carry the fields on the dispatched note)
- Test: `workers/api/src/twist/tools/plot/note.structured.test.ts` (new) OR extend an existing note test

**Interfaces:**
- Consumes: `NewNote.sectionKey/sectionLabel/sectionPosition/itemPosition` (Task 2).
- Produces: `createNote` persists them to the `note` row; `buildNoteAndThread` sets them on the dispatched `Note` (default `null`).

- [ ] **Step 1: Write the failing test** (the write path)

Grep an existing `note.ts` / createNote test to mirror its harness (`workers/api/src/twist/tools/plot/*.test.ts`). Skeleton asserting the dbNote carries the section fields:
```typescript
import { describe, expect, it, vi } from "vitest";
// import { createNote } from "./note"; + the existing test harness (db stub capturing the insert values)

describe("createNote — structured-item fields", () => {
  it("persists sectionKey/sectionLabel/sectionPosition/itemPosition to the note row", async () => {
    // Arrange: a NewNote with section fields, using the existing createNote test seam
    // (capture the values passed to db.insertInto('note').values(...)).
    const captured = await runCreateNote({
      thread: { id: "t1" },
      key: "checkitem-1",
      content: "Do the thing",
      sectionKey: "checklist-9",
      sectionLabel: "QA",
      sectionPosition: "a0",
      itemPosition: "a1",
    });
    expect(captured.section_key).toBe("checklist-9");
    expect(captured.section_label).toBe("QA");
    expect(captured.section_position).toBe("a0");
    expect(captured.item_position).toBe("a1");
  });
});
```
> If the existing createNote tests use a real DB (`DATABASE_URL`-gated, `describe.skipIf`), follow that pattern and run with the worktree override; otherwise use the unit seam. Inspect the neighbors first and match.

- [ ] **Step 2: Run → FAIL** (`cd workers/api && pnpm vitest run src/twist/tools/plot/note.structured.test.ts`).

- [ ] **Step 3: Implement the write path**

In `workers/api/src/twist/tools/plot/note.ts`, in the `dbNote` object (~lines 532–564), add (mirroring the `content` field):
```typescript
    section_key: note.sectionKey ?? null,
    section_label: note.sectionLabel ?? null,
    section_position: note.sectionPosition ?? null,
    item_position: note.itemPosition ?? null,
```
(If `createNote` also has an UPDATE/upsert branch for keyed notes, add the same four to that update set so edits propagate.)

- [ ] **Step 4: Expose on the dispatched note**

In `workers/api/src/twist/tools/integrations.ts` `buildNoteAndThread` (~2230), add to the `note` object literal (the dispatch query must also select these columns — add `section_key/section_label/section_position/item_position` to the note-dispatch SELECT that produces `item`; grep the query feeding `dispatch()`):
```typescript
    sectionKey: item.section_key ?? null,
    sectionLabel: item.section_label ?? null,
    sectionPosition: item.section_position ?? null,
    itemPosition: item.item_position ?? null,
    tagActors: {}, // populated in Task 4
```

- [ ] **Step 5: Run → PASS**; `cd workers/api && pnpm exec tsc --noEmit` clean.

- [ ] **Step 6: Commit** (main repo): `git add workers/api/src/twist/tools/plot/note.ts workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/plot/note.structured.test.ts && git commit -m "feat(api): persist + dispatch note structured-item fields"`

---

### Task 4: Runtime — dispatch-time `tagActors` enrichment from `contact_external_account`

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (`dispatch()` note path, after `buildNoteAndThread`)
- Test: `workers/api/src/twist/tools/integrations.tagactors.test.ts` (new)

**Interfaces:**
- Consumes: `note.tags` (`Record<tagId, ActorId[]>`), `this.twistInstanceId`, `this.db`.
- Produces: `note.tagActors` = `Record<ActorId, Actor>` — every distinct actor id across all `tags`, each with `source.accountId` set from `contact_external_account` (scoped to `this.twistInstanceId`) when a row exists (`source: null` when not). Also sets `note.author.source` when the author has a row.

- [ ] **Step 1: Write the failing test**

`workers/api/src/twist/tools/integrations.tagactors.test.ts`:
```typescript
import { describe, expect, it, vi } from "vitest";
import { Integrations } from "./integrations";

// Build an Integrations with a stubbed db that returns external-account rows.
function makeIntegrations(rows: Array<{ id: string; name: string | null; account_id: string }>) {
  const db = {
    selectFrom: vi.fn(() => db),
    innerJoin: vi.fn(() => db),
    select: vi.fn(() => db),
    where: vi.fn(() => db),
    execute: vi.fn(async () => rows),
    executeTakeFirst: vi.fn(async () => undefined),
  } as any;
  const i = Object.create(Integrations.prototype);
  i.db = db;
  i.twistInstanceId = "twist-1";
  return i as Integrations & { enrichTagActors: (note: any) => Promise<void> };
}

describe("tagActors enrichment", () => {
  it("maps each tag actor id to an Actor with source.accountId from contact_external_account", async () => {
    const i = makeIntegrations([
      { id: "actor-a", name: "Alice", account_id: "trello-mem-A" },
      { id: "actor-b", name: "Bob", account_id: "trello-mem-B" },
    ]);
    const note: any = { tags: { "1": ["actor-a", "actor-b"], "3": ["actor-a"] }, author: { id: "actor-a", type: 1 }, tagActors: {} };
    await (i as any).enrichTagActors(note);
    expect(note.tagActors["actor-a"].source).toEqual({ accountId: "trello-mem-A" });
    expect(note.tagActors["actor-b"].source).toEqual({ accountId: "trello-mem-B" });
    // author enriched too
    expect(note.author.source).toEqual({ accountId: "trello-mem-A" });
  });

  it("sets source null for actors with no external account row", async () => {
    const i = makeIntegrations([]); // no rows
    const note: any = { tags: { "1": ["actor-x"] }, author: { id: "actor-x", type: 1 }, tagActors: {} };
    await (i as any).enrichTagActors(note);
    expect(note.tagActors["actor-x"].source).toBeNull();
  });
});
```

- [ ] **Step 2: Run → FAIL** (`enrichTagActors` not defined).

- [ ] **Step 3: Implement the enrichment helper + call it in dispatch**

Add a private method to `Integrations` (near `buildNoteAndThread`):
```typescript
/**
 * Hydrate note.tagActors (and note.author.source) with each actor's external
 * account id for THIS connector, from contact_external_account scoped to this
 * twist instance. One batched query; no per-actor lookup. Lets a connector
 * resolve an assignee to its external id (e.g. Trello member) on write-back.
 */
private async enrichTagActors(note: Note): Promise<void> {
  const ids = new Set<string>();
  for (const actorIds of Object.values(note.tags ?? {})) {
    for (const id of actorIds as string[]) ids.add(id);
  }
  if (note.author?.id) ids.add(note.author.id as string);
  if (ids.size === 0) return;

  const rows = await this.db
    .selectFrom("contact_external_account")
    .innerJoin("contact", "contact.id", "contact_external_account.contact_id")
    .where("contact_external_account.twist_instance_id", "=", this.twistInstanceId)
    .where("contact_external_account.contact_id", "in", [...ids])
    .select(["contact.id", "contact.name", "contact_external_account.account_id"])
    .execute();

  const byId = new Map(rows.map((r) => [r.id as string, r.account_id as string]));
  const actorFor = (id: string): Actor => ({
    id: id as any,
    type: ActorType.Contact,
    source: byId.has(id) ? { accountId: byId.get(id)! } : null,
  });

  const tagActors: Record<string, Actor> = {};
  for (const id of ids) tagActors[id] = actorFor(id);
  note.tagActors = tagActors as any;
  if (note.author?.id) {
    const acc = byId.get(note.author.id as string);
    note.author.source = acc ? { accountId: acc } : null;
  }
}
```
Then call it in `dispatch()` (the note path) right after `const { note, thread } = await this.buildNoteAndThread(item);` and before returning the `onNoteCreated`/`onNoteUpdated` dispatch:
```typescript
await this.enrichTagActors(note);
```
Wrap the DB call so a failure degrades to empty enrichment rather than dropping the dispatch (the assignment write-back simply won't resolve that cycle): catch, `tracker?.captureException?.(error)` if a tracker is in scope here (else `createLogger().error(...)`), leave `tagActors = {}`.

- [ ] **Step 4: Run → PASS**; tsc clean.

- [ ] **Step 5: Commit** (main repo): `git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations.tagactors.test.ts && git commit -m "feat(api): enrich dispatched note assignees with external account ids"`

---

### Task 5: Finalize — schema sync, types, lint, test sweep

**Files:** verification only.

- [ ] **Step 1: Schema + types in sync**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations            # no differences
pnpm --filter @plotday/db run lint     # types.ts matches DB (the db:lint CI check)
```

- [ ] **Step 2: TS typecheck + the new tests**

```bash
cd workers/api && pnpm exec tsc --noEmit && pnpm vitest run src/twist/tools/plot/note.structured.test.ts src/twist/tools/integrations.tagactors.test.ts
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/twister && pnpm exec tsc --noEmit
```
Expected: all clean / green.

- [ ] **Step 3: Lint changed packages**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/workers/api && pnpm lint
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/twister && pnpm lint
```
Fix Trello/structured-item-related lint; note unrelated pre-existing errors, don't fix.

- [ ] **Step 4: Commit any fixups** (main repo + submodule as applicable).

---

## Out of scope (handled elsewhere)

- **Drift/Flutter client columns + grouped/ordered/collapsed checklist UI + capability gating** → Plan 5 (client). Until then the structured-item data reaches Postgres + the `user.note` sync payload but isn't stored/rendered locally.
- **Trello checklist sync** (checkItem → structured-item note, two-way completion/assignment/rename) → Plan 4 (consumes this foundation).
- **The `tagActors` surfacing shape** is decided here (a `Record<ActorId, Actor>` companion map on the dispatched `Note`) rather than mutating the shared `Tags` type — additive, backward-compatible.

## Self-Review

**Spec coverage (Part 3, Layer 1 — server/SDK):** note `section_*`/`item_position` columns + `user.note` (T1) ✓ · Twister `Note`/`NewNote` fields (T2) ✓ · `Actor.source` (T2) ✓ · runtime write of section fields (T3) ✓ · **actor external-account enrichment at dispatch, no connector lookup** (T4) ✓ · changeset (T2) ✓ · types.ts/schema sync (T1, T5) ✓. Drift columns + UI explicitly deferred to Plan 5 (documented).

**Type consistency:** column names `section_key/section_label/section_position/item_position` (snake, DB) ↔ `sectionKey/sectionLabel/sectionPosition/itemPosition` (camel, Twister + dbNote mapping) consistent across T1/T2/T3. `Actor.source.accountId` shape identical in T2 (type) and T4 (enrichment). `tagActors: Record<ActorId, Actor>` defined in T2, populated in T4, consumed by Plan 4. `this.twistInstanceId` is the scoping key in T4's query (matches the existing `contact_external_account` query pattern).

**Placeholder scan:** the T3 test harness note ("inspect the neighbors, match the createNote test seam") is a verification instruction with a concrete skeleton + fallback, not an unfilled blank. The migration file name is generated by Atlas (not authored). No TODO/TBD.

**DB-hazard check:** every migration step carries the explicit `source .worktree-db && export DATABASE_URL=...` override; the controller-note flags Task 1 for careful (controller-run or override-hammered) execution.
