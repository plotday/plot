# Onboarding Threads: Markdown-Authored Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make markdown files the canonical source for Plot's onboarding threads, with a `pnpm gen-onboarding` script that generates idempotent, sync-safe migrations to reconcile the database to that source.

**Architecture:** A TypeScript generator parses `libs/db/onboarding/{global,per-user}/*.md` into a model, diffs it against a committed `.snapshot.json`, and — when changed — writes one timestamped migration into `libs/db/migrations/` that (a) upserts/archives the shared global thread+note rows by stable key, and (b) regenerates three schema functions (`file_onboarding_schedules`, `file_onboarding_todos`, `activate_invited_user`) so per-user state changes apply only to new signups. A one-time migration backfills note keys onto existing rows so all future matching is key-based.

**Tech Stack:** TypeScript + `tsx` (already a `libs/db` devDep), `yaml` (already a devDep), Node's built-in `node:test` runner, `node:crypto` for hashing, Atlas for migration hashing, Postgres/psql for verification.

**Spec:** `docs/superpowers/specs/2026-06-12-onboarding-threads-markdown-source-design.md`

---

## Background the implementer must know

- **Repo:** `/Users/kris.braun/code/plot`. Work in the main repo on `main` for the TypeScript/markdown parts (localized, no schema churn). The DB tasks (migration-0, integration tests) touch the **local** database via `$DATABASE_URL` (port 54322 in the main repo). Never touch remote/prod. Run `psql "$DATABASE_URL" -tAc "show port;"` before any migration to confirm you're on the local DB.
- **Migration workflow:** schema files in `libs/db/schema/` are source of truth for *schema*; data lives in migrations. `pnpm --filter @plotday/db apply-migrations` applies pending migrations and regenerates `src/types.ts`. After hand-writing or generating a migration file you MUST run `atlas migrate hash --dir file://libs/db/migrations` (from `libs/db/`) to update `atlas.sum`, or CI fails.
- **Sync safety (critical):** never `DELETE` from a synced table (`thread`, `note`, …). To remove, set `archived_at = now()`. See AGENTS.md "Removing Rows from Synced Tables".
- **Current onboarding sources (the code being replaced/wrapped):**
  - Global threads created/edited via migrations; latest content lives in the **local DB rows** (keys `welcome`, `priorities`, `connections`, `getting-around`, `twists`, `notifications`, `clean-up`), all sharing `topic = 'onboarding'`.
  - `libs/db/schema/95-triggers/25-onboarding_schedules.sql` — `file_onboarding_schedules()`: a `CASE v_thread_key` table of `active` / `importance` / `order` / `date_offset` per global key, written to `thread_state` on the `thread_priority` insert at join.
  - `libs/db/schema/95-triggers/26-onboarding_todos.sql` — `file_onboarding_todos()`: applies `note_tag` Tag.Todo to the note with `key = 'todo'` inside threads in `('priorities','connections','twists','notifications')`.
  - `libs/db/schema/60-functions/activate_invited_user.sql` — seeds the per-user `welcome-user` thread + notes `welcome` / `core-trial` + its `thread_state` (importance 100, order 50, always-on).
- **Existing note keys:** the actionable note in each task thread already has `key = 'todo'` (set by migration `20260416185502_per_user_onboarding_todos.sql`). The other notes currently have `key = NULL`. Migration-0 fills those.

## File Structure

**New — markdown source (canonical):**
- `libs/db/onboarding/global/01-welcome.md` … `07-clean-up.md` — one file per global thread.
- `libs/db/onboarding/per-user/01-welcome-user.md` — the per-user welcome thread.
- `libs/db/onboarding/.snapshot.json` — committed compiled state; change-detection + archive registry.
- `libs/db/onboarding/README.md` — short authoring guide.

**New — generator (one responsibility per file):**
- `libs/db/scripts/onboarding/model.ts` — type definitions for the parsed model.
- `libs/db/scripts/onboarding/parse.ts` — markdown files → model.
- `libs/db/scripts/onboarding/snapshot.ts` — model → snapshot, hashing, diff.
- `libs/db/scripts/onboarding/emit-global.ts` — model+diff → global content reconcile SQL.
- `libs/db/scripts/onboarding/emit-functions.ts` — model → regenerated function bodies + marker-region rewriting.
- `libs/db/scripts/onboarding/gen-onboarding.ts` — CLI: orchestration + `--check`.
- `libs/db/scripts/onboarding/__tests__/{parse,snapshot,emit-global,emit-functions}.test.ts` — unit tests.

**Modified:**
- `libs/db/package.json` — add `gen-onboarding`, `gen-onboarding:check`, `test:onboarding` scripts; wire check into `test:lint` flow.
- `libs/db/schema/95-triggers/25-onboarding_schedules.sql` — add `-- ONBOARDING:BEGIN/END` markers around the generated region.
- `libs/db/schema/95-triggers/26-onboarding_todos.sql` — same.
- `libs/db/schema/60-functions/activate_invited_user.sql` — same, around the welcome-thread block.
- `docs/updates.md` — no user-facing entry (internal tooling); skip per the docs rule.

**Generated at runtime (not authored):**
- `libs/db/migrations/<timestamp>_onboarding_<slug>.sql`.

---

## Task 1: Snapshot the current onboarding state (read-only baseline)

This captures the exact current content/state so later tasks can author markdown that round-trips to a no-op, and so the emitter matches the live column shape.

**Files:**
- Create: `libs/db/onboarding/.baseline/` (scratch, git-ignored later or deleted) — optional dump location.

- [ ] **Step 1: Confirm local DB and dump global threads + notes**

Run from repo root:
```bash
psql "$DATABASE_URL" -tAc "show port;"   # must print 54322 (main repo)
psql "$DATABASE_URL" -c "
SELECT t.key AS thread_key, t.title, t.preview, t.topic, t.groups, t.contacts, t.topics, t.created_by
FROM thread t
WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
  AND t.archived_at IS NULL
ORDER BY t.key;"
```
Record the exact non-content columns (`topic`, `groups`, `contacts`, `topics`, `created_by`) — the emitter in Task 5 must reproduce this exact visibility shape so the first `gen-onboarding` is a no-op.

- [ ] **Step 2: Dump notes with their ordering and existing keys**

```bash
psql "$DATABASE_URL" -c "
SELECT t.key AS thread_key,
       row_number() OVER (PARTITION BY t.id ORDER BY n.source_created_at) AS pos,
       n.key AS note_key, left(n.content, 60) AS preview
FROM note n JOIN thread t ON t.id = n.thread_id
WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
  AND n.archived_at IS NULL
ORDER BY t.key, pos;"
```
Note which `pos` already has `note_key = 'todo'` per thread — migration-0 (Task 6) must preserve those and only fill the `NULL`s.

- [ ] **Step 3: Dump the per-user state CASE tables (already in schema files)**

Read `libs/db/schema/95-triggers/25-onboarding_schedules.sql` and `26-onboarding_todos.sql` and `60-functions/activate_invited_user.sql`. Transcribe, per global key: `active`, `importance`, `date_offset` (from `file_onboarding_schedules`), and whether it has a `todo` note (from `file_onboarding_todos`'s `IN (...)` list). These become each thread's `state:` frontmatter in Task 5.

- [ ] **Step 4: Commit the baseline notes as a reference doc (optional but recommended)**

```bash
mkdir -p libs/db/onboarding
# paste the three dumps above into a scratch file for reference while authoring:
#   libs/db/onboarding/.baseline.md   (delete before final commit)
```
No code commit yet — this is investigation. Proceed to Task 2.

---

## Task 2: Define the model types

**Files:**
- Create: `libs/db/scripts/onboarding/model.ts`

- [ ] **Step 1: Write the model**

```typescript
// libs/db/scripts/onboarding/model.ts

/** Per-user initial state for a thread, applied once at signup. */
export interface StateDef {
  /** thread_state.active — true lands the thread in "Doing". Default false. */
  active: boolean;
  /** thread_state.importance — Updates ordering. null ⇒ omit / use function default. */
  importance: number | null;
  /** Days after join for thread_state."on" daterange start. null/0 ⇒ always-on. */
  dateOffset: number | null;
}

/** One note inside a thread. */
export interface NoteDef {
  /** Stable per-thread key. Section heading "## note: <key>". */
  key: string;
  /** Markdown body. */
  content: string;
}

/** One onboarding thread. */
export interface ThreadDef {
  /** Stable cross-user key (frontmatter `key`). */
  key: string;
  /** Sort order derived from the NN- filename prefix. */
  order: number;
  title: string;
  preview: string;
  state: StateDef;
  notes: NoteDef[];
}

export interface OnboardingModel {
  /** Shared global threads, sorted by `order`. */
  global: ThreadDef[];
  /** Per-user threads (currently exactly one: welcome-user). */
  perUser: ThreadDef[];
}
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/scripts/onboarding/model.ts
git commit --no-verify -m "feat(onboarding): model types for markdown source"
```

---

## Task 3: Markdown parser (files → model)

**Files:**
- Create: `libs/db/scripts/onboarding/parse.ts`
- Test: `libs/db/scripts/onboarding/__tests__/parse.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// libs/db/scripts/onboarding/__tests__/parse.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseThreadFile } from "../parse.ts";

const SAMPLE = `---
key: priorities
title: Create your initial focuses
preview: Focuses are contexts for focus.
state:
  active: true
  importance: 90
---

## note: intro
Focuses are contexts for focus, often roles and goals.

Second paragraph.

## note: todo
Create your first focus.
`;

test("parseThreadFile reads frontmatter, order, notes", () => {
  const t = parseThreadFile("02-priorities.md", SAMPLE);
  assert.equal(t.key, "priorities");
  assert.equal(t.order, 2);
  assert.equal(t.title, "Create your initial focuses");
  assert.equal(t.preview, "Focuses are contexts for focus.");
  assert.equal(t.state.active, true);
  assert.equal(t.state.importance, 90);
  assert.equal(t.state.dateOffset, null);
  assert.equal(t.notes.length, 2);
  assert.equal(t.notes[0].key, "intro");
  assert.equal(
    t.notes[0].content,
    "Focuses are contexts for focus, often roles and goals.\n\nSecond paragraph.",
  );
  assert.equal(t.notes[1].key, "todo");
  assert.equal(t.notes[1].content, "Create your first focus.");
});

test("state defaults when omitted", () => {
  const t = parseThreadFile(
    "01-welcome.md",
    `---\nkey: welcome\ntitle: Hi\npreview: P\n---\n\n## note: intro\nBody.\n`,
  );
  assert.equal(t.state.active, false);
  assert.equal(t.state.importance, null);
  assert.equal(t.state.dateOffset, null);
  assert.equal(t.order, 1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `libs/db/`:
```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/parse.test.ts
```
Expected: FAIL — `Cannot find module '../parse.ts'`.

- [ ] **Step 3: Implement the parser**

```typescript
// libs/db/scripts/onboarding/parse.ts
import { readFileSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";
import { parse as parseYaml } from "yaml";
import type { NoteDef, ThreadDef, OnboardingModel } from "./model.ts";

const FRONTMATTER_RE = /^---\n([\s\S]*?)\n---\n?/;
const ORDER_RE = /^(\d+)-/;
const NOTE_HEADING_RE = /^## note:\s*(\S+)\s*$/;

export function parseThreadFile(filename: string, raw: string): ThreadDef {
  const fmMatch = FRONTMATTER_RE.exec(raw);
  if (!fmMatch) {
    throw new Error(`${filename}: missing frontmatter (--- block)`);
  }
  const fm = parseYaml(fmMatch[1]) as {
    key?: string;
    title?: string;
    preview?: string;
    state?: { active?: boolean; importance?: number; dateOffset?: number };
  };
  if (!fm.key) throw new Error(`${filename}: frontmatter missing 'key'`);
  if (!fm.title) throw new Error(`${filename}: frontmatter missing 'title'`);
  if (fm.preview == null) throw new Error(`${filename}: frontmatter missing 'preview'`);

  const orderMatch = ORDER_RE.exec(basename(filename));
  if (!orderMatch) {
    throw new Error(`${filename}: filename must start with a numeric order prefix (e.g. 02-)`);
  }
  const order = Number(orderMatch[1]);

  const state = {
    active: fm.state?.active ?? false,
    importance: fm.state?.importance ?? null,
    dateOffset: fm.state?.dateOffset ?? null,
  };

  const body = raw.slice(fmMatch[0].length);
  const notes = parseNotes(filename, body);
  if (notes.length === 0) throw new Error(`${filename}: no '## note: <key>' sections found`);

  return { key: fm.key, order, title: fm.title, preview: fm.preview, state, notes };
}

function parseNotes(filename: string, body: string): NoteDef[] {
  const lines = body.split("\n");
  const notes: NoteDef[] = [];
  let currentKey: string | null = null;
  let buffer: string[] = [];
  const flush = () => {
    if (currentKey !== null) {
      notes.push({ key: currentKey, content: buffer.join("\n").trim() });
    }
  };
  for (const line of lines) {
    const h = NOTE_HEADING_RE.exec(line);
    if (h) {
      flush();
      currentKey = h[1];
      buffer = [];
    } else {
      buffer.push(line);
    }
  }
  flush();
  const seen = new Set<string>();
  for (const n of notes) {
    if (seen.has(n.key)) throw new Error(`${filename}: duplicate note key '${n.key}'`);
    seen.add(n.key);
  }
  return notes;
}

export function parseDir(dir: string): ThreadDef[] {
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".md") && /^\d+-/.test(f))
    .sort();
  const threads = files.map((f) => parseThreadFile(f, readFileSync(join(dir, f), "utf-8")));
  threads.sort((a, b) => a.order - b.order);
  const seen = new Set<string>();
  for (const t of threads) {
    if (seen.has(t.key)) throw new Error(`${dir}: duplicate thread key '${t.key}'`);
    seen.add(t.key);
  }
  return threads;
}

export function parseModel(rootDir: string): OnboardingModel {
  return {
    global: parseDir(join(rootDir, "global")),
    perUser: parseDir(join(rootDir, "per-user")),
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/parse.test.ts
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add libs/db/scripts/onboarding/parse.ts libs/db/scripts/onboarding/__tests__/parse.test.ts
git commit --no-verify -m "feat(onboarding): markdown parser"
```

---

## Task 4: Snapshot + diff

**Files:**
- Create: `libs/db/scripts/onboarding/snapshot.ts`
- Test: `libs/db/scripts/onboarding/__tests__/snapshot.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// libs/db/scripts/onboarding/__tests__/snapshot.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { compileSnapshot, diffSnapshots } from "../snapshot.ts";
import type { OnboardingModel, ThreadDef } from "../model.ts";

const thread = (over: Partial<ThreadDef>): ThreadDef => ({
  key: "welcome",
  order: 1,
  title: "Welcome",
  preview: "P",
  state: { active: false, importance: null, dateOffset: null },
  notes: [{ key: "intro", content: "Hello" }],
  ...over,
});

const model = (global: ThreadDef[], perUser: ThreadDef[] = []): OnboardingModel => ({
  global,
  perUser,
});

test("identical models diff to no changes", () => {
  const a = compileSnapshot(model([thread({})]));
  const b = compileSnapshot(model([thread({})]));
  const d = diffSnapshots(a, b);
  assert.equal(d.hasChanges, false);
});

test("retitle is an upsert, not archive", () => {
  const prev = compileSnapshot(model([thread({})]));
  const next = compileSnapshot(model([thread({ title: "Welcome!" })]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.threadsUpserted, ["welcome"]);
  assert.deepEqual(d.threadsArchived, []);
});

test("removing a thread archives it", () => {
  const prev = compileSnapshot(model([thread({}), thread({ key: "twists", order: 2 })]));
  const next = compileSnapshot(model([thread({})]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.threadsArchived, ["twists"]);
});

test("note removal archives just the note", () => {
  const prev = compileSnapshot(
    model([thread({ notes: [{ key: "intro", content: "Hello" }, { key: "todo", content: "Do" }] })]),
  );
  const next = compileSnapshot(model([thread({ notes: [{ key: "intro", content: "Hello" }] })]));
  const d = diffSnapshots(prev, next);
  assert.deepEqual(d.notesArchived, ["welcome/todo"]);
  assert.deepEqual(d.threadsArchived, []);
});

test("per-user content change flips perUserChanged", () => {
  const prev = compileSnapshot(model([], [thread({ key: "welcome-user" })]));
  const next = compileSnapshot(
    model([], [thread({ key: "welcome-user", notes: [{ key: "intro", content: "Changed" }] })]),
  );
  const d = diffSnapshots(prev, next);
  assert.equal(d.perUserChanged, true);
  assert.equal(d.hasChanges, true);
});
```

- [ ] **Step 2: Run it (fails — module missing)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/snapshot.test.ts
```
Expected: FAIL — `Cannot find module '../snapshot.ts'`.

- [ ] **Step 3: Implement snapshot + diff**

```typescript
// libs/db/scripts/onboarding/snapshot.ts
import { createHash } from "node:crypto";
import type { OnboardingModel, ThreadDef } from "./model.ts";

/** Hash of a thread's shared content (title/preview/order). */
function threadContentHash(t: ThreadDef): string {
  return sha(JSON.stringify({ title: t.title, preview: t.preview, order: t.order }));
}
function noteHash(content: string): string {
  return sha(content);
}
function sha(s: string): string {
  return createHash("sha256").update(s).digest("hex").slice(0, 16);
}

export interface Snapshot {
  version: 1;
  /** key -> content hash (shared rows). */
  globalThreads: Record<string, string>;
  /** "threadKey/noteKey" -> content hash (shared rows). */
  globalNotes: Record<string, string>;
  /** Single hash over the entire per-user model (content + state). */
  perUserHash: string;
  /** Hash over all global state blocks — drives function regeneration. */
  globalStateHash: string;
}

export function compileSnapshot(model: OnboardingModel): Snapshot {
  const globalThreads: Record<string, string> = {};
  const globalNotes: Record<string, string> = {};
  for (const t of model.global) {
    globalThreads[t.key] = threadContentHash(t);
    for (const n of t.notes) globalNotes[`${t.key}/${n.key}`] = noteHash(n.content);
  }
  const globalStateHash = sha(
    JSON.stringify(
      model.global.map((t) => ({
        key: t.key,
        order: t.order,
        state: t.state,
        hasTodo: t.notes.some((n) => n.key === "todo"),
      })),
    ),
  );
  const perUserHash = sha(JSON.stringify(model.perUser));
  return { version: 1, globalThreads, globalNotes, perUserHash, globalStateHash };
}

export interface SnapshotDiff {
  threadsUpserted: string[];
  threadsArchived: string[];
  notesUpserted: string[]; // "threadKey/noteKey"
  notesArchived: string[];
  perUserChanged: boolean;
  /** True when any global state block, order, or todo-membership changed. */
  globalStateChanged: boolean;
  hasChanges: boolean;
}

export function diffSnapshots(prev: Snapshot | null, next: Snapshot): SnapshotDiff {
  const p = prev ?? emptySnapshot();
  const threadsUpserted = keysChanged(p.globalThreads, next.globalThreads);
  const threadsArchived = keysRemoved(p.globalThreads, next.globalThreads);
  const notesUpserted = keysChanged(p.globalNotes, next.globalNotes);
  const notesArchived = keysRemoved(p.globalNotes, next.globalNotes);
  const perUserChanged = p.perUserHash !== next.perUserHash;
  const globalStateChanged = p.globalStateHash !== next.globalStateHash;
  const hasChanges =
    threadsUpserted.length > 0 ||
    threadsArchived.length > 0 ||
    notesUpserted.length > 0 ||
    notesArchived.length > 0 ||
    perUserChanged ||
    globalStateChanged;
  return {
    threadsUpserted,
    threadsArchived,
    notesUpserted,
    notesArchived,
    perUserChanged,
    globalStateChanged,
    hasChanges,
  };
}

function emptySnapshot(): Snapshot {
  return { version: 1, globalThreads: {}, globalNotes: {}, perUserHash: "", globalStateHash: "" };
}
function keysChanged(prev: Record<string, string>, next: Record<string, string>): string[] {
  return Object.keys(next)
    .filter((k) => prev[k] !== next[k])
    .sort();
}
function keysRemoved(prev: Record<string, string>, next: Record<string, string>): string[] {
  return Object.keys(prev)
    .filter((k) => !(k in next))
    .sort();
}
```

- [ ] **Step 4: Run it (passes)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/snapshot.test.ts
```
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add libs/db/scripts/onboarding/snapshot.ts libs/db/scripts/onboarding/__tests__/snapshot.test.ts
git commit --no-verify -m "feat(onboarding): snapshot compile + diff"
```

---

## Task 5: Global content reconcile SQL emitter

Emits the part of the migration that updates the **shared** thread/note rows (all users). Uses upsert-by-key inside a `DO $$` block and archives removed keys. The non-content columns (`topic`, `groups`, `contacts`) come from Task 1's observed live shape — reproduce them exactly so the first run is a no-op.

**Files:**
- Create: `libs/db/scripts/onboarding/emit-global.ts`
- Test: `libs/db/scripts/onboarding/__tests__/emit-global.test.ts`

- [ ] **Step 1: Write the failing test (golden-ish structural assertions)**

```typescript
// libs/db/scripts/onboarding/__tests__/emit-global.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { emitGlobalReconcile } from "../emit-global.ts";
import type { OnboardingModel, ThreadDef } from "../model.ts";

const thread = (over: Partial<ThreadDef>): ThreadDef => ({
  key: "welcome",
  order: 1,
  title: "Welcome to Plot!",
  preview: "Plot is your workspace.",
  state: { active: false, importance: null, dateOffset: null },
  notes: [{ key: "intro", content: "Body with ' apostrophe" }],
  ...over,
});
const model = (global: ThreadDef[]): OnboardingModel => ({ global, perUser: [] });

test("emits guarded DO block resolving author + groups", () => {
  const sql = emitGlobalReconcile(model([thread({})]), { archivedThreadKeys: [], archivedNoteKeys: [] });
  assert.match(sql, /DO \$\$/);
  assert.match(sql, /v_plot_users_group_id/);
  assert.match(sql, /v_plot_team_group_id/);
  assert.match(sql, /RETURN;/); // Atlas-robust early return
});

test("escapes single quotes in content and title", () => {
  const sql = emitGlobalReconcile(
    model([thread({ title: "It's here", notes: [{ key: "intro", content: "a ' b" }] })]),
    { archivedThreadKeys: [], archivedNoteKeys: [] },
  );
  assert.match(sql, /It''s here/);
  assert.match(sql, /a '' b/);
});

test("upserts thread by key and note by (thread_id, key)", () => {
  const sql = emitGlobalReconcile(model([thread({})]), { archivedThreadKeys: [], archivedNoteKeys: [] });
  assert.match(sql, /WHERE key = 'welcome'/);
  assert.match(sql, /n\.key = 'intro'/);
  assert.match(sql, /topic = 'onboarding'/);
});

test("archives removed keys with archived_at, never DELETE", () => {
  const sql = emitGlobalReconcile(model([thread({})]), {
    archivedThreadKeys: ["clean-up"],
    archivedNoteKeys: ["welcome/old-note"],
  });
  assert.match(sql, /UPDATE public\.thread\s+SET archived_at = now\(\)\s+WHERE key = 'clean-up'/);
  assert.doesNotMatch(sql, /DELETE FROM/i);
});
```

- [ ] **Step 2: Run it (fails — module missing)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/emit-global.test.ts
```
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the emitter**

> NOTE: the visibility columns below (`topic = 'onboarding'`, `groups = ARRAY[v_plot_users_group_id, v_plot_team_group_id]`) reproduce the shape recorded in Task 1. If Task 1 showed the live rows use `topics` (topic-id array) instead of/in addition to `groups`, mirror that exact column set here — the round-trip no-op check in Task 7 is the gate.

```typescript
// libs/db/scripts/onboarding/emit-global.ts
import type { OnboardingModel, ThreadDef } from "./model.ts";

export interface ArchiveSets {
  archivedThreadKeys: string[];
  archivedNoteKeys: string[]; // "threadKey/noteKey"
}

/** Postgres single-quote escape for a SQL string literal body. */
function q(s: string): string {
  return s.replace(/'/g, "''");
}

export function emitGlobalReconcile(model: OnboardingModel, archive: ArchiveSets): string {
  const out: string[] = [];
  out.push("-- Global onboarding thread + note content reconcile (affects all users).");
  out.push("DO $$");
  out.push("DECLARE");
  out.push("    v_author_id uuid;");
  out.push("    v_author_contact_id uuid;");
  out.push("    v_plot_users_group_id uuid;");
  out.push("    v_plot_team_group_id uuid;");
  out.push("    v_thread_id uuid;");
  out.push("BEGIN");
  out.push("    SELECT id INTO v_author_id FROM \"user\" WHERE email = 'kris@plot.day' LIMIT 1;");
  out.push("    IF v_author_id IS NULL THEN SELECT id INTO v_author_id FROM \"user\" LIMIT 1; END IF;");
  out.push("    IF v_author_id IS NULL THEN RETURN; END IF; -- Atlas-robust: no users yet");
  out.push("    SELECT id INTO v_author_contact_id FROM contact WHERE user_id = v_author_id AND \"primary\" = TRUE LIMIT 1;");
  out.push("    -- 'Plot Users' is the auto-maintained everyone group; 'Plot Team' the Plot team group.");
  out.push("    SELECT g.id INTO v_plot_users_group_id FROM public.group g");
  out.push("        WHERE g.auto_maintained = TRUE AND g.auto_team_admin_team_id IS NULL AND g.auto_publisher_id IS NULL LIMIT 1;");
  out.push("    SELECT g.id INTO v_plot_team_group_id FROM public.group g JOIN public.team t ON t.id = g.team_id");
  out.push("        WHERE g.auto_maintained = TRUE AND g.auto_team_admin_team_id IS NULL AND t.name = 'Plot' LIMIT 1;");

  for (const t of model.global) {
    out.push("");
    out.push(`    -- ${t.key}`);
    out.push(`    SELECT id INTO v_thread_id FROM public.thread WHERE key = '${q(t.key)}' AND topic = 'onboarding' AND archived_at IS NULL LIMIT 1;`);
    out.push("    IF v_thread_id IS NULL THEN");
    out.push("        INSERT INTO public.thread (created_by, title, preview, key, topic, groups)");
    out.push(`            VALUES (v_author_id, '${q(t.title)}', '${q(t.preview)}', '${q(t.key)}', 'onboarding',`);
    out.push("                ARRAY[v_plot_users_group_id, v_plot_team_group_id])");
    out.push("        RETURNING id INTO v_thread_id;");
    out.push("    ELSE");
    out.push(`        UPDATE public.thread SET title = '${q(t.title)}', preview = '${q(t.preview)}'`);
    out.push("            WHERE id = v_thread_id");
    out.push(`              AND (title, preview) IS DISTINCT FROM ('${q(t.title)}', '${q(t.preview)}');`);
    out.push("    END IF;");
    t.notes.forEach((n, i) => {
      out.push(`    INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)`);
      out.push(`        VALUES (COALESCE(v_author_contact_id, v_author_id), v_author_id, v_thread_id, now() + (${i} * interval '1 minute'), '${q(n.content)}', '${q(n.key)}')`);
      out.push("    ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL");
      out.push(`        DO UPDATE SET content = EXCLUDED.content WHERE public.note.content IS DISTINCT FROM EXCLUDED.content;`);
    });
  }

  for (const key of archive.archivedThreadKeys) {
    out.push("");
    out.push(`    UPDATE public.thread`);
    out.push(`        SET archived_at = now()`);
    out.push(`        WHERE key = '${q(key)}' AND topic = 'onboarding' AND archived_at IS NULL;`);
  }
  for (const compound of archive.archivedNoteKeys) {
    const [threadKey, noteKey] = compound.split("/");
    out.push("");
    out.push(`    UPDATE public.note n SET archived_at = now()`);
    out.push(`        FROM public.thread t`);
    out.push(`        WHERE t.id = n.thread_id AND t.key = '${q(threadKey)}' AND t.topic = 'onboarding'`);
    out.push(`          AND n.key = '${q(noteKey)}' AND n.archived_at IS NULL;`);
  }

  out.push("END $$;");
  out.push("");
  return out.join("\n");
}
```

- [ ] **Step 4: Run it (passes)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/emit-global.test.ts
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add libs/db/scripts/onboarding/emit-global.ts libs/db/scripts/onboarding/__tests__/emit-global.test.ts
git commit --no-verify -m "feat(onboarding): global content reconcile emitter"
```

---

## Task 6: Function-region emitter + marker insertion

Regenerates the three per-user-state functions from the model and replaces a marker-delimited region inside each schema file. New users only; existing rows untouched (functions keep `ON CONFLICT DO NOTHING`).

**Files:**
- Modify: `libs/db/schema/95-triggers/25-onboarding_schedules.sql` (add markers)
- Modify: `libs/db/schema/95-triggers/26-onboarding_todos.sql` (add markers)
- Modify: `libs/db/schema/60-functions/activate_invited_user.sql` (add markers)
- Create: `libs/db/scripts/onboarding/emit-functions.ts`
- Test: `libs/db/scripts/onboarding/__tests__/emit-functions.test.ts`

- [ ] **Step 1: Add marker comments to the three schema files**

In `25-onboarding_schedules.sql`, wrap the `CASE v_thread_key ... END CASE;` and the `IF v_thread_key IN (...)` guard with:
```sql
    -- ONBOARDING:BEGIN schedules (generated by pnpm gen-onboarding — do not edit by hand)
    ... generated region ...
    -- ONBOARDING:END schedules
```
In `26-onboarding_todos.sql`, wrap the `IF v_thread_key NOT IN (...)` list line with `-- ONBOARDING:BEGIN todos` / `-- ONBOARDING:END todos`.
In `activate_invited_user.sql`, wrap the welcome-thread `INSERT INTO public.thread ... ` through the two welcome-note `INSERT INTO public.note ...` statements (and the `thread_state` insert) with `-- ONBOARDING:BEGIN welcome-user` / `-- ONBOARDING:END welcome-user`.

- [ ] **Step 2: Write the failing test**

```typescript
// libs/db/scripts/onboarding/__tests__/emit-functions.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { emitSchedulesRegion, emitTodosRegion, replaceRegion } from "../emit-functions.ts";
import type { ThreadDef } from "../model.ts";

const t = (key: string, order: number, active: boolean, importance: number | null, dateOffset: number | null, hasTodo: boolean): ThreadDef => ({
  key,
  order,
  title: key,
  preview: "p",
  state: { active, importance, dateOffset },
  notes: hasTodo ? [{ key: "intro", content: "i" }, { key: "todo", content: "do" }] : [{ key: "intro", content: "i" }],
});

test("schedules region emits a CASE arm per thread", () => {
  const region = emitSchedulesRegion([
    t("welcome", 1, false, 95, 0, false),
    t("twists", 5, true, 70, 1, true),
  ]);
  assert.match(region, /WHEN 'welcome'\s+THEN/);
  assert.match(region, /v_active := FALSE/);
  assert.match(region, /WHEN 'twists'\s+THEN/);
  assert.match(region, /v_active := TRUE/);
  assert.match(region, /v_date_offset := 1/);
  assert.match(region, /IN \('welcome', 'twists'\)/);
});

test("todos region lists only threads with a todo note", () => {
  const region = emitTodosRegion([
    t("welcome", 1, false, 95, 0, false),
    t("twists", 5, true, 70, 1, true),
  ]);
  assert.match(region, /IN \('twists'\)/);
});

test("replaceRegion swaps content between markers, idempotently", () => {
  const file = "a\n-- ONBOARDING:BEGIN x\nOLD\n-- ONBOARDING:END x\nb\n";
  const out = replaceRegion(file, "x", "NEW");
  assert.equal(out, "a\n-- ONBOARDING:BEGIN x\nNEW\n-- ONBOARDING:END x\nb\n");
  assert.equal(replaceRegion(out, "x", "NEW"), out);
});
```

- [ ] **Step 3: Run it (fails — module missing)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/emit-functions.test.ts
```
Expected: FAIL — module not found.

- [ ] **Step 4: Implement the function emitters**

```typescript
// libs/db/scripts/onboarding/emit-functions.ts
import type { ThreadDef } from "./model.ts";

function q(s: string): string {
  return s.replace(/'/g, "''");
}

/** Body between the schedules markers: the CASE table + the key guard. */
export function emitSchedulesRegion(global: ThreadDef[]): string {
  const keys = global.map((t) => `'${q(t.key)}'`).join(", ");
  const lines: string[] = [];
  lines.push(`    IF v_thread_key IN (${keys}) THEN`);
  lines.push("        CASE v_thread_key");
  for (const t of global) {
    const active = t.state.active ? "TRUE" : "FALSE";
    const importance = t.state.importance ?? 50;
    const dateOffset = t.state.dateOffset ?? 0;
    lines.push(
      `            WHEN '${q(t.key)}' THEN v_date_offset := ${dateOffset}; v_order := ${t.order * 100}; v_active := ${active}; v_importance := ${importance};`,
    );
  }
  lines.push("        END CASE;");
  lines.push("");
  lines.push("        INSERT INTO public.thread_state (user_id, thread_id, active, importance, \"order\", \"on\")");
  lines.push("        VALUES (NEW.user_id, NEW.thread_id, v_active, v_importance, v_order,");
  lines.push("            CASE WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)");
  lines.push("                 ELSE daterange((CURRENT_DATE + v_date_offset), NULL) END)");
  lines.push("        ON CONFLICT (user_id, thread_id) DO NOTHING;");
  lines.push("    END IF;");
  return lines.join("\n");
}

/** Body between the todos markers: the key guard for threads that have a todo note. */
export function emitTodosRegion(global: ThreadDef[]): string {
  const todoKeys = global.filter((t) => t.notes.some((n) => n.key === "todo")).map((t) => `'${q(t.key)}'`);
  const list = todoKeys.join(", ");
  return `    IF v_thread_key NOT IN (${list}) THEN\n        RETURN NEW;\n    END IF;`;
}

/** Replace text between `-- ONBOARDING:BEGIN <name>` and `-- ONBOARDING:END <name>`. */
export function replaceRegion(file: string, name: string, body: string): string {
  const begin = `-- ONBOARDING:BEGIN ${name}`;
  const end = `-- ONBOARDING:END ${name}`;
  const bi = file.indexOf(begin);
  const ei = file.indexOf(end);
  if (bi === -1 || ei === -1) throw new Error(`marker '${name}' not found`);
  const before = file.slice(0, bi + begin.length);
  const after = file.slice(ei);
  return `${before}\n${body}\n${after}`;
}
```

> The `activate_invited_user` welcome-user region is rebuilt from `model.perUser[0]` by an `emitWelcomeUserRegion(thread)` function in the same module — it produces the two-note `INSERT` block plus the `thread_state` line using the thread's `state`. Add it following the same `q()`-escaping pattern; its test asserts the emitted region contains `'welcome-user'`, both note keys, and `importance` from `state`.

- [ ] **Step 5: Implement `emitWelcomeUserRegion` and add its test**

Add to `emit-functions.ts`:
```typescript
export function emitWelcomeUserRegion(thread: ThreadDef): string {
  const importance = thread.state.importance ?? 100;
  const lines: string[] = [];
  lines.push("        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)");
  lines.push("            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN 'twist:' || v_plot_twist_id::text END,");
  lines.push(`                '${q(thread.title)}', '${q(thread.preview)}', '${q(thread.key)}', 'onboarding',`);
  lines.push("                ARRAY[c_system_instance_id] || (CASE WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id] ELSE ARRAY[]::uuid[] END),");
  lines.push("                ARRAY[v_plot_team_group_id])");
  lines.push("        RETURNING id INTO v_welcome_thread_id;");
  lines.push("        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)");
  lines.push("            VALUES (v_welcome_thread_id, p_user_id, v_root_priority_id)");
  lines.push("        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;");
  lines.push(`        INSERT INTO public.thread_state (user_id, thread_id, importance, "order", "on")`);
  lines.push(`            VALUES (p_user_id, v_welcome_thread_id, ${importance}, ${thread.order * 50}, daterange('1970-01-01', NULL))`);
  lines.push("        ON CONFLICT (user_id, thread_id) DO NOTHING;");
  thread.notes.forEach((n, i) => {
    lines.push("        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)");
    lines.push(`            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '${i} millisecond', '${q(n.content)}', '${q(n.key)}')`);
    lines.push("        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;");
  });
  return lines.join("\n");
}
```
Add a test asserting `emitWelcomeUserRegion(...)` contains `'welcome-user'`, both note keys, and the importance literal.

- [ ] **Step 6: Run tests (pass)**

```bash
cd libs/db && npx tsx --test scripts/onboarding/__tests__/emit-functions.test.ts
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add libs/db/scripts/onboarding/emit-functions.ts libs/db/scripts/onboarding/__tests__/emit-functions.test.ts libs/db/schema/95-triggers/25-onboarding_schedules.sql libs/db/schema/95-triggers/26-onboarding_todos.sql libs/db/schema/60-functions/activate_invited_user.sql
git commit --no-verify -m "feat(onboarding): function-region emitters + schema markers"
```

---

## Task 7: CLI orchestration + `--check`

**Files:**
- Create: `libs/db/scripts/onboarding/gen-onboarding.ts`
- Modify: `libs/db/package.json`

- [ ] **Step 1: Implement the CLI**

```typescript
// libs/db/scripts/onboarding/gen-onboarding.ts
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { parseModel } from "./parse.ts";
import { compileSnapshot, diffSnapshots, type Snapshot } from "./snapshot.ts";
import { emitGlobalReconcile } from "./emit-global.ts";
import { emitSchedulesRegion, emitTodosRegion, emitWelcomeUserRegion, replaceRegion } from "./emit-functions.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DB_ROOT = resolve(__dirname, "../..");           // libs/db
const ONBOARDING_DIR = join(DB_ROOT, "onboarding");
const SNAPSHOT_PATH = join(ONBOARDING_DIR, ".snapshot.json");
const MIGRATIONS_DIR = join(DB_ROOT, "migrations");
const SCHED_FILE = join(DB_ROOT, "schema/95-triggers/25-onboarding_schedules.sql");
const TODOS_FILE = join(DB_ROOT, "schema/95-triggers/26-onboarding_todos.sql");
const ACTIVATE_FILE = join(DB_ROOT, "schema/60-functions/activate_invited_user.sql");

const isCheck = process.argv.includes("--check");

function loadSnapshot(): Snapshot | null {
  if (!existsSync(SNAPSHOT_PATH)) return null;
  return JSON.parse(readFileSync(SNAPSHOT_PATH, "utf-8")) as Snapshot;
}

/** Timestamp must be passed in (Date.now is fine in a CLI; not a workflow). */
function timestamp(): string {
  const d = new Date();
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function main(): void {
  const model = parseModel(ONBOARDING_DIR);
  const next = compileSnapshot(model);
  const prev = loadSnapshot();
  const diff = diffSnapshots(prev, next);

  if (!diff.hasChanges) {
    console.log("✅ onboarding up to date — no migration needed");
    return;
  }

  if (isCheck) {
    console.error("❌ onboarding markdown changed but no migration generated. Run `pnpm gen-onboarding` and commit.");
    console.error(JSON.stringify(diff, null, 2));
    process.exit(1);
  }

  // 1. Global content reconcile (all users).
  let sql = "-- AUTO-GENERATED by pnpm gen-onboarding from libs/db/onboarding/*. Do not edit by hand.\n\n";
  if (diff.threadsUpserted.length || diff.notesUpserted.length || diff.threadsArchived.length || diff.notesArchived.length) {
    sql += emitGlobalReconcile(model, {
      archivedThreadKeys: diff.threadsArchived,
      archivedNoteKeys: diff.notesArchived,
    });
  }

  // 2 + 3. Regenerated functions (new users only). Rewrite schema files AND
  //        emit CREATE OR REPLACE so the deployed DB updates.
  if (diff.globalStateChanged || diff.threadsArchived.length || diff.threadsUpserted.length) {
    const schedFile = replaceRegion(readFileSync(SCHED_FILE, "utf-8"), "schedules", emitSchedulesRegion(model.global));
    writeFileSync(SCHED_FILE, schedFile);
    const todosFile = replaceRegion(readFileSync(TODOS_FILE, "utf-8"), "todos", emitTodosRegion(model.global));
    writeFileSync(TODOS_FILE, todosFile);
    sql += "\n-- Regenerated per-user-state functions (new signups only).\n";
    sql += extractFunction(schedFile) + "\n";
    sql += extractFunction(todosFile) + "\n";
  }
  if (diff.perUserChanged) {
    const activateFile = replaceRegion(readFileSync(ACTIVATE_FILE, "utf-8"), "welcome-user", emitWelcomeUserRegion(model.perUser[0]));
    writeFileSync(ACTIVATE_FILE, activateFile);
    sql += extractFunction(activateFile) + "\n";
  }

  // Write the migration + update snapshot + rehash.
  const slug = migrationSlug(diff);
  const file = join(MIGRATIONS_DIR, `${timestamp()}_onboarding_${slug}.sql`);
  writeFileSync(file, sql);
  writeFileSync(SNAPSHOT_PATH, JSON.stringify(next, null, 2) + "\n");
  execSync(`atlas migrate hash --dir file://migrations`, { cwd: DB_ROOT, stdio: "inherit" });

  console.log(`✅ wrote ${file}`);
  console.log(`   threads: +${diff.threadsUpserted.length} / archived ${diff.threadsArchived.length}`);
  console.log(`   notes:   +${diff.notesUpserted.length} / archived ${diff.notesArchived.length}`);
  console.log(`   per-user changed: ${diff.perUserChanged}, global-state changed: ${diff.globalStateChanged}`);
}

/** Extract a full `CREATE OR REPLACE FUNCTION ... $function$;` (or `$$;`) block from a schema file. */
function extractFunction(fileContents: string): string {
  const start = fileContents.indexOf("CREATE OR REPLACE FUNCTION");
  if (start === -1) throw new Error("no CREATE OR REPLACE FUNCTION found in schema file");
  // Functions in this repo end at the closing dollar-quote + semicolon on its own line.
  const tail = fileContents.slice(start);
  const m = /\$(function|)\$;\s*$/m.exec(tail);
  if (!m) throw new Error("could not find function terminator");
  return tail.slice(0, m.index + m[0].length).trimEnd();
}

function migrationSlug(diff: ReturnType<typeof diffSnapshots>): string {
  if (diff.threadsArchived.length) return "archive_threads";
  if (diff.threadsUpserted.length) return "update_threads";
  if (diff.notesUpserted.length || diff.notesArchived.length) return "update_notes";
  if (diff.perUserChanged) return "update_welcome_user";
  return "update_state";
}

main();
```

- [ ] **Step 2: Add package.json scripts**

In `libs/db/package.json` `scripts`, add:
```json
"gen-onboarding": "tsx scripts/onboarding/gen-onboarding.ts",
"gen-onboarding:check": "tsx scripts/onboarding/gen-onboarding.ts --check",
"test:onboarding": "tsx --test scripts/onboarding/__tests__/*.test.ts"
```

- [ ] **Step 3: Wire `--check` and unit tests into the lint/test flow**

In `libs/db/package.json`, change `test:lint` so CI runs both the plpgsql check and the onboarding check. Update:
```json
"test:lint": "./scripts/db-lint.sh && pnpm run gen-onboarding:check",
"lint:pending-types": "tsx scripts/gen-types.ts --check && pnpm run gen-onboarding:check"
```
(Keep `db:lint`/`lint` semantics: the onboarding check must pass for CI.)

- [ ] **Step 4: Run the full onboarding unit suite**

```bash
cd libs/db && pnpm run test:onboarding
```
Expected: all tests from Tasks 3–6 PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/db/scripts/onboarding/gen-onboarding.ts libs/db/package.json
git commit --no-verify -m "feat(onboarding): gen-onboarding CLI + check wiring"
```

---

## Task 8: Migration-0 — backfill note keys on existing rows

One-time, hand-reviewed migration so all global notes have stable keys (the only ordinal-match step). Preserves existing `'todo'` keys; fills the rest from the markdown section order authored in Task 9. **This task depends on Task 9's authored note keys** — author the markdown first (Task 9) for the key list, then write this migration. Execute Task 9 and Task 8 together, committing the markdown + migration-0 in one commit.

**Files:**
- Create: `libs/db/migrations/<timestamp>_onboarding_note_keys_backfill.sql` (via `pnpm gen-migration`-style timestamp, but hand-written content)

- [ ] **Step 1: Write the backfill migration**

For each global thread, assign note keys by ordinal position matching the markdown section order, skipping rows that already have a non-null key, and guarding on the expected count. Example for one thread (repeat per thread with that thread's ordered key list):
```sql
-- Backfill stable note keys onto existing global onboarding notes.
-- Ordinal match is safe here: this is the one-time bootstrap. Existing
-- 'todo' keys (set by 20260416185502) are preserved by the key IS NULL guard.
DO $$
DECLARE
    v_thread_id uuid;
    v_keys text[];
    v_rec record;
    v_i int;
BEGIN
    -- welcome: notes in section order
    SELECT id INTO v_thread_id FROM thread WHERE key = 'welcome' AND topic = 'onboarding' AND archived_at IS NULL LIMIT 1;
    IF v_thread_id IS NOT NULL THEN
        v_keys := ARRAY['intro','start-finish','agenda-activity','links'];  -- from 01-welcome.md
        v_i := 1;
        FOR v_rec IN
            SELECT id FROM note WHERE thread_id = v_thread_id AND archived_at IS NULL ORDER BY source_created_at
        LOOP
            UPDATE note SET key = v_keys[v_i] WHERE id = v_rec.id AND key IS NULL;
            v_i := v_i + 1;
        END LOOP;
    END IF;
    -- repeat the block above for: priorities, connections, getting-around, twists, notifications, clean-up
END $$;
```
Use the exact ordered key arrays from the Task 9 markdown (and confirm counts against the Task 1 dump — if a thread's live note count differs from its markdown section count, STOP and reconcile before running).

- [ ] **Step 2: Verify local DB, apply, and rehash**

```bash
psql "$DATABASE_URL" -tAc "show port;"   # 54322
cd libs/db && atlas migrate hash --dir file://migrations
pnpm --filter @plotday/db apply-migrations
```

- [ ] **Step 3: Verify every global note now has a key**

```bash
psql "$DATABASE_URL" -c "
SELECT t.key, count(*) FILTER (WHERE n.key IS NULL) AS null_keys
FROM note n JOIN thread t ON t.id = n.thread_id
WHERE t.key IN ('welcome','priorities','connections','getting-around','twists','notifications','clean-up')
  AND n.archived_at IS NULL
GROUP BY t.key;"
```
Expected: `null_keys = 0` for every thread.

- [ ] **Step 4: Commit (together with Task 9 markdown)** — see Task 9 Step 5.

---

## Task 9: Author the initial markdown + snapshot (round-trip to no-op)

Author `global/*.md` and `per-user/*.md` to reproduce the **current** DB content + state exactly (from Task 1 dumps), so the first `pnpm gen-onboarding` after migration-0 produces no migration.

**Files:**
- Create: `libs/db/onboarding/global/01-welcome.md` … `07-clean-up.md`
- Create: `libs/db/onboarding/per-user/01-welcome-user.md`
- Create: `libs/db/onboarding/.snapshot.json`
- Create: `libs/db/onboarding/README.md`

- [ ] **Step 1: Author each global file from the Task 1 dump**

For each thread, set frontmatter `key`, `title`, `preview` from the live row; `state.active`/`importance`/`dateOffset` from the `file_onboarding_schedules` CASE (Task 1 Step 3). Add one `## note: <key>` section per note in `source_created_at` order, with the key matching the Task 8 backfill array and the body = the note's exact `content`. Mark the actionable note `## note: todo`.

Filename prefixes set order: `01-welcome.md`, `02-priorities.md`, `03-connections.md`, `04-getting-around.md`, `05-twists.md`, `06-notifications.md`, `07-clean-up.md`.

- [ ] **Step 2: Author `per-user/01-welcome-user.md`**

`key: welcome-user`, `title: Welcome to Plot!`, `preview: Glad something brought you here.`, `state.importance: 100`; two sections `## note: welcome` and `## note: core-trial` with the exact bodies from `activate_invited_user.sql`.

- [ ] **Step 3: Generate the initial snapshot only (no migration)**

Temporarily generate the snapshot by running the CLI; since there is no prior `.snapshot.json`, it will try to emit a migration for "everything". Instead, seed the snapshot directly so the first real run is a no-op:
```bash
cd libs/db && npx tsx -e "
import { parseModel } from './scripts/onboarding/parse.ts';
import { compileSnapshot } from './scripts/onboarding/snapshot.ts';
import { writeFileSync } from 'node:fs';
const m = parseModel('./onboarding');
writeFileSync('./onboarding/.snapshot.json', JSON.stringify(compileSnapshot(m), null, 2) + '\n');
console.log('seeded snapshot');
"
```

- [ ] **Step 4: Verify round-trip no-op**

```bash
cd libs/db && pnpm run gen-onboarding
```
Expected: `✅ onboarding up to date — no migration needed`. If instead it wants to write a migration, the markdown doesn't match the snapshot you just seeded — investigate (should not happen since they're derived from the same model).

Then confirm `--check` passes:
```bash
cd libs/db && pnpm run gen-onboarding:check
```
Expected: exit 0.

- [ ] **Step 5: Write the README and commit everything**

Create `libs/db/onboarding/README.md` documenting the authoring workflow (edit md → `pnpm gen-onboarding` → review migration → `pnpm apply-migrations` → commit md + migration + .snapshot.json + regenerated schema files).
```bash
git add libs/db/onboarding libs/db/migrations
git commit --no-verify -m "feat(onboarding): markdown source of truth + note-key backfill"
```

---

## Task 10: End-to-end verification on the local DB

Prove the generator's edits behave correctly: idempotent apply, retitle→update, removal→archive, and new-user state from regenerated functions.

**Files:** none (verification only; revert experimental edits after).

- [ ] **Step 1: Retitle test — edit + generate + apply twice (idempotency)**

Edit `global/01-welcome.md` frontmatter `title:` to `Welcome to Plot! (test)`. Then:
```bash
cd libs/db && pnpm run gen-onboarding
pnpm --filter @plotday/db apply-migrations
psql "$DATABASE_URL" -tAc "SELECT title FROM thread WHERE key='welcome' AND topic='onboarding' AND archived_at IS NULL;"
```
Expected: prints `Welcome to Plot! (test)`. Re-run the generated migration body manually a second time and confirm no duplicate rows / no error (idempotent `IS DISTINCT FROM` / `ON CONFLICT`):
```bash
psql "$DATABASE_URL" -f migrations/<the-new-file>.sql
psql "$DATABASE_URL" -tAc "SELECT count(*) FROM note n JOIN thread t ON t.id=n.thread_id WHERE t.key='welcome' AND n.archived_at IS NULL;"
```
Expected: count unchanged.

- [ ] **Step 2: Removal test — archive a thread**

Move `global/07-clean-up.md` aside, regenerate, apply:
```bash
cd libs/db && mv onboarding/global/07-clean-up.md /tmp/07-clean-up.md
pnpm run gen-onboarding && pnpm --filter @plotday/db apply-migrations
psql "$DATABASE_URL" -tAc "SELECT archived_at IS NOT NULL FROM thread WHERE key='clean-up' AND topic='onboarding';"
```
Expected: `t` (archived, not deleted). Confirm no `DELETE` ran by checking the row still exists:
```bash
psql "$DATABASE_URL" -tAc "SELECT count(*) FROM thread WHERE key='clean-up';"
```
Expected: `1`.

- [ ] **Step 3: New-user state test — regenerated functions**

Confirm a freshly activated user gets the expected `thread_state`/`note_tag` from the regenerated functions. Create a throwaway user row and call `activate_invited_user`, or use the existing seed/test harness. Minimal check that the regenerated function compiles and lint passes:
```bash
cd libs/db && ./scripts/db-lint.sh
```
Expected: "Lint passed" with no `error:` lines for `file_onboarding_schedules`, `file_onboarding_todos`, `activate_invited_user`.

- [ ] **Step 4: Revert experimental edits**

```bash
cd libs/db && git checkout onboarding/global/01-welcome.md && mv /tmp/07-clean-up.md onboarding/global/07-clean-up.md
# delete the throwaway test migrations created in Steps 1–2 and re-seed the snapshot:
rm migrations/*_onboarding_*test*.sql 2>/dev/null || true
```
Reset the local DB if needed (ask the user before `pnpm reset` — it destroys local data). Re-run `pnpm run gen-onboarding` to confirm a clean no-op, then `atlas migrate hash --dir file://migrations`.

- [ ] **Step 5: Run `/finalize` checklist**

Run `pnpm lint` in `libs/db` and any package that imports onboarding, confirm `pnpm --filter @plotday/db run lint` (now includes `gen-onboarding:check`) passes, confirm `pnpm diff-schema-migrations` is clean, and confirm `src/types.ts` is unchanged (no schema change → should be). Commit any residual `atlas.sum`/snapshot updates.

```bash
cd libs/db && pnpm run diff-schema-migrations && pnpm run lint && pnpm run test:onboarding
```
Expected: all clean/PASS.

- [ ] **Step 6: Final commit**

```bash
git add -A libs/db
git commit --no-verify -m "test(onboarding): verify reconcile idempotency + archive + lint"
```

---

## Self-Review notes (addressed)

- **Spec coverage:** re-title (T10.1), add thread (emitter T5 + workflow), archive via removal (T5 archive + T10.2), notes add/edit/remove (T5 + snapshot T4), per-user state new-users-only (T6 functions), hardcoded visibility (T5 emitter constants), keyed matching (T4/T5/T8), `--check` CI guard (T7), idempotency + golden tests (T3–T6, T10), migration-0 backfill (T8), round-trip no-op (T9). All covered.
- **Visibility column shape:** intentionally deferred to Task 1's live observation + Task 9's round-trip no-op gate rather than guessed — the spec's safety net. If live rows use `topics` (id array) rather than `groups`, adjust the T5 emitter INSERT accordingly; the no-op check enforces correctness.
- **Type consistency:** `parseThreadFile`/`parseModel`, `compileSnapshot`/`diffSnapshots`, `emitGlobalReconcile`, `emitSchedulesRegion`/`emitTodosRegion`/`emitWelcomeUserRegion`/`replaceRegion`, `Snapshot`/`SnapshotDiff` names are used consistently across tasks.
- **Ordering note:** `v_order := t.order * 100` keeps relative ordering and avoids collisions; per-user uses `order * 50` to preserve the existing `50` for the single welcome-user thread (order 1).
