# Phase 1 — Twister `"none"` sharing model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `"none"` value to the connector `sharingModel` union so link types with no recipient roster (e.g. Google Tasks) can declare it, and set Google Tasks to use it.

**Architecture:** Pure contract change in `@plotday/twister` (the SDK) plus one connector declaration. No runtime behavior in the SDK depends on the value — it's resolved client-side (Flutter, a later phase) and is otherwise descriptive. This phase is independent and safe to land first: clients that don't yet know `"none"` already fall back to `"thread"`, which is Google Tasks' current value, and Google Tasks composes to a task-list channel (no contact picker) regardless.

**Tech Stack:** TypeScript, `@plotday/twister`, pnpm workspaces, changesets.

**Location:** All edits are inside the `public/` git submodule. Per `public/AGENTS.md`, `public/` changes are a **separate commit/PR in the submodule**, then the main repo commits the bumped submodule pointer. Only `twister/` changes get a changeset; the Google Tasks connector change must NOT get its own changeset.

---

### Task 1: Add `"none"` to the `sharingModel` union

**Files:**
- Modify: `public/twister/src/tools/integrations.ts:128-144`

- [ ] **Step 1: Extend the JSDoc to document `"none"`**

In `public/twister/src/tools/integrations.ts`, replace the `sharingModel` JSDoc + type (currently lines ~128-144):

```ts
  /**
   * Declares how sharing on threads of this link type is scoped:
   *
   * - `"thread"` (default): one roster shared across all notes in the
   *   thread. Native Plot threads, Slack DMs, calendar events.
   * - `"channel"`: visibility is the external channel's membership;
   *   the per-thread `contacts` array is ignored for sharing UI.
   *   Slack channels, Linear projects.
   * - `"message"`: each note carries its own recipient set via
   *   `note.access_contacts`; the thread roster is the union across
   *   all messages. Email.
   *
   * Omit to default to `"thread"`. When set to `"message"`, every
   * note this connector ingests must populate `access_contacts`
   * explicitly (never NULL).
   */
  sharingModel?: "thread" | "channel" | "message";
```

with:

```ts
  /**
   * Declares how sharing on threads of this link type is scoped:
   *
   * - `"thread"` (default): one roster shared across all notes in the
   *   thread. Native Plot threads, Slack DMs, calendar events.
   * - `"channel"`: visibility is the external channel's membership;
   *   the per-thread `contacts` array is ignored for sharing UI.
   *   Slack channels, Linear projects.
   * - `"message"`: each note carries its own recipient set via
   *   `note.access_contacts`; the thread roster is the union across
   *   all messages. Email.
   * - `"none"`: the link type has no recipient roster at all. No
   *   contacts/sharing UI is shown for these threads. Use for purely
   *   personal destinations with no sharing concept (e.g. Google
   *   Tasks). The per-thread `contacts` array is ignored for sharing UI.
   *
   * Omit to default to `"thread"`. When set to `"message"`, every
   * note this connector ingests must populate `access_contacts`
   * explicitly (never NULL).
   */
  sharingModel?: "thread" | "channel" | "message" | "none";
```

- [ ] **Step 2: Check for other enumerations of the sharing-model values and update them**

Run:

```bash
cd /Users/kris.braun/code/plot
rg -n '"thread"\s*\|\s*"channel"\s*\|\s*"message"|sharingModel' public/twister/src workers/api/src
```

Expected: the only `"thread" | "channel" | "message"` literal union is the one just edited in `integrations.ts`. If any other copy exists (a re-export, a Zod schema, or a runtime validator in `workers/api/src`), add `"none"` there too. If the search shows only the edited line plus comment mentions, no further change is needed.

- [ ] **Step 3: Build twister to verify the type compiles**

```bash
cd /Users/kris.braun/code/plot/public/twister && pnpm build
```
Expected: build succeeds (exit 0), `dist/tools/integrations.d.ts` now contains `"thread" | "channel" | "message" | "none"`. Verify:

```bash
rg -n 'sharingModel' /Users/kris.braun/code/plot/public/twister/dist/tools/integrations.d.ts
```
Expected: shows the 4-value union.

---

### Task 2: Add the changeset (required for any `twister/` change)

**Files:**
- Create: `public/.changeset/twister-sharing-model-none.md`

- [ ] **Step 1: Write the changeset**

```markdown
---
"@plotday/twister": minor
---

Added: `"none"` sharing model for `LinkTypeConfig.sharingModel`. Link types with no recipient roster (e.g. Google Tasks) can declare `sharingModel: "none"` so Plot shows no contacts/sharing UI for their threads.
```

- [ ] **Step 2: Validate the changeset**

```bash
cd /Users/kris.braun/code/plot/public && pnpm validate-changesets
```
Expected: passes with no errors (a `minor` bump targeting only `@plotday/twister` is valid).

---

### Task 3: Set Google Tasks to `sharingModel: "none"`

**Files:**
- Modify: `public/connectors/google-tasks/src/google-tasks.ts:67`

- [ ] **Step 1: Change the link type's sharing model**

In `public/connectors/google-tasks/src/google-tasks.ts`, in the `linkTypes` array (the `type: "task"` entry, ~line 67), change:

```ts
      sharingModel: "thread" as const,
```
to:
```ts
      sharingModel: "none" as const,
```

Do **not** add a changeset for this file — connector packages are excluded from changesets (`public/AGENTS.md`).

- [ ] **Step 2: Typecheck the connector against the rebuilt twister**

```bash
cd /Users/kris.braun/code/plot/public/connectors/google-tasks && pnpm lint
```
Expected: passes (the `"none" as const` now satisfies the widened union). If the connector has no `lint` script, run its typecheck instead:
```bash
cd /Users/kris.braun/code/plot/public/connectors/google-tasks && npx tsc --noEmit
```
Expected: no type errors.

---

### Task 4: Verify the workspace consumers still build

**Files:** none (verification only)

- [ ] **Step 1: Refresh the workspace link and lint API**

```bash
cd /Users/kris.braun/code/plot && pnpm install
pnpm --filter @plotday/api lint
```
Expected: `pnpm install` updates the `@plotday/twister` workspace link; the API lint passes (the API consumes `LinkTypeConfig`; the widened union is backward-compatible).

---

### Task 5: Commit (submodule first, then pointer bump)

- [ ] **Step 1: Commit inside the `public/` submodule on a feature branch**

```bash
cd /Users/kris.braun/code/plot/public
git checkout -b feat/sharing-model-none
git add twister/src/tools/integrations.ts .changeset/twister-sharing-model-none.md connectors/google-tasks/src/google-tasks.ts
git commit -m "feat(twister): add \"none\" sharing model; set Google Tasks to none" -- twister/src/tools/integrations.ts .changeset/twister-sharing-model-none.md connectors/google-tasks/src/google-tasks.ts
```

- [ ] **Step 2: Bump the submodule pointer in the main repo**

```bash
cd /Users/kris.braun/code/plot
git add public
git commit -m "chore: bump public submodule (twister \"none\" sharing model)" -- public
```

Note: opening the actual PR for the `public/` submodule is a finalize/release step (`/finalize`), not part of local execution. Do not deploy.

---

## Phase 1 self-check

- `sharingModel` union has 4 values; twister `dist` reflects it.
- Changeset present and valid; targets only `@plotday/twister`.
- Google Tasks declares `"none"`; connector + API typecheck clean.
- No Flutter changes here — `ln.none` is added in Phase 3; until then clients resolve unknown values to `ln.thread` (harmless: Google Tasks already behaved as `thread` and composes to a channel with no contact picker).
