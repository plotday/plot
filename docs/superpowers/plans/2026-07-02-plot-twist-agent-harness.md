# Plot Twist Agent Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `twists/plot` from a chatbot-with-tools into a correct, budget-aware agent harness: approved plans actually execute, the tool surface is chainable and workspace-wide, turns survive step/context budgets, and long work continues in the background.

**Architecture:** Three layers change. (1) **SDK** (`public/twister`): the plan-action contract gains `approved`/`results` fields and a `createFocus` operation. (2) **Server** (`workers/api`): the orphaned `executePlan` is rewritten for current operation shapes and wired into the `/callback/:token` approval path — operations execute server-side with a full-access Plot tool, results attach to the action, and the twist callback receives `(action, approved)`. (3) **Twist** (`twists/plot`): split into focused modules; tools return IDs and search workspace-wide; the blind second-pipeline planner becomes a `proposeOperations` tool whose Gemini Pro sub-call sees conversation context and defers focus creation into the plan; the loop gets step-budget continuation, transient retry, a progress note, a per-thread lock, history compaction, and a `runTask` background handoff.

**Tech Stack:** TypeScript (Cloudflare Workers, Vercel AI SDK v5 via `this.tools.ai`), Typebox schemas, vitest, Flutter/Dart (plan card rendering), pnpm workspace + `public/` git submodule.

## Global Constraints

- Work in an isolated **worktree** (create via `superpowers:using-git-worktrees` at execution start). No DB schema changes → no `worktree-db` needed.
- `public/` submodule changes: create a branch inside `public/` first (`cd public && git checkout -b plot-twist-agent-harness`), rebuild Twister after type changes (`cd public/twister && pnpm build`), and **every** `public/twister/src` change needs a changeset in `public/.changeset/` (minor, `Added:`/`Changed:` prefix). Submodule commits are separate from main-repo commits.
- Static imports only; never `import()` dynamically.
- If TS2589 ("Type instantiation is excessively deep") appears, add `// @ts-ignore` with a comment above the offending line.
- Workers: unexpected-error catch blocks must call `captureException`/`captureServerError`. Twists are sandboxed (no PostHog) — `console.error` is the only sink there; do NOT add capture calls inside `twists/plot`.
- Local only. Never deploy. Never touch the remote DB.
- Do not edit `workers/api/src/twist/entrypoint.ts` (template-literal backtick hazard) — no task here requires it.
- Commit after each task (subagent-driven flow) with conventional-commit messages. Never amend on a shared branch.

**Existing type facts (verified 2026-07-02, cite when in doubt):**
- `PlanOperation` union: `public/twister/src/plot.ts:1305` (`updateThread` w/ `changes.focus?: {id,title}`, `updateLink`, `createThread` w/ `focusId`/`focusTitle`, `createNote`, `updateFocus`).
- Plan action variant: `public/twister/src/plot.ts:322-331` — `{ type: ActionType.plan; title; operations; callback }`, doc already promises "Callback invoked with (action, approved: boolean)".
- `NewFocus` accepts explicit `{ id: Uuid }` (`plot.ts:134`); `FocusUpdate = ({id}|{key}) & Partial<Pick<Focus,"title"|"archived">>` (`plot.ts:161`).
- `ThreadUpdate` single-update supports `focus?: Pick<Focus,"id">`, `title`, `archived`, `type` (ThreadSingleUpdateFields).
- `NewThread` supports `focus?: Pick<Focus,"id">` (`plot.ts:503`).
- `createNote` returns `Promise<Uuid>` (`public/twister/src/tools/plot.ts:415`).
- `SearchOptions.focusId` omitted ⇒ server searches **all** the owner's focuses (`tools/plot.ts:128-138`); limit default 10, max 30.
- Plot tool Options: `thread?: {access?, defaultMention?}`, `note?: {defaultMention?, intents?, handler?}`, `link?: true | {access?: LinkAccess}`, `focus?: {access?}`, `search?: true`, `requireApproval?: true` (`public/twister/src/tools/plot.ts:220`).
- Server `Plot` is directly constructible: `new Plot({ db, twistInstanceId, options, env, sourceProvider? })` (`workers/api/src/twist/tools/plot/index.ts:290-310`); existing tests do this (`workers/api/src/twist/tools/__tests__/plot.test.ts:163`).
- `invokeWebhookCallback(env, ctx, fullToken, ...args)` passes extra args straight to the twist callback; curried `extraArgs` from `actionCallback` are appended AFTER call-time args.
- Base tools `store`/`tasks`/`callbacks` are ALWAYS available to twists without declaring them in `build()` (`public/twister/src/utils/types.ts:43-45`). Lock API: `this.tools.store.acquireLock(key, ttlMs): Promise<boolean>`, `releaseLock(key)`.
- AI: `prompt()` blocking, no retries; `maxSteps` default 1, no cap; `finishReason` includes `"tool-calls"`/`"length"`; `response.response?.messages?: AIMessage[]` (`public/twister/src/tools/ai.ts:434-441`). Model matrix (Plot-funded): fast+high → Gemini 2.5 Flash; capable+high → Gemini 2.5 Pro (`workers/api/src/twist/tools/ai.ts:242-257`).
- Flutter plan card: `apps/plot/lib/widget/note_action.dart:327` (`PlanActionWidget`, POSTs `plan.toJson() + {approved}` to `/callback/:token`); op rendering: `apps/plot/lib/store/user_action.dart:305` (`PlanOperation.description` getter — currently renders the **legacy** `updatePriority`/`changes.priority` shapes, stale).

**Task dependency graph:**
- Task 1 (SDK) → Tasks 2, 3, 6
- Task 4 (module split) → Tasks 5 → 6 → 7 → 8 → 9 → 10 (sequential, all touch `twists/plot`)
- Task 2 (server) ∥ Task 3 (Flutter) ∥ Task 4 — parallelizable after Task 1
- Task 11 (docs + finalize) last

---

### Task 1: SDK plan-action contract (`public/twister`)

**Files:**
- Modify: `public/twister/src/plot.ts` (plan Action variant ~line 322; `PlanOperation` union ~line 1305)
- Create: `public/.changeset/plan-execution-contract.md`

**Interfaces:**
- Consumes: existing `PlanOperation`, `ActionType.plan`, `Uuid`, `Callback` types.
- Produces (used by Tasks 2, 3, 6):
  - `export type PlanOperationResult = { success: boolean; error?: string };`
  - `PlanOperation` gains variant `{ type: "createFocus"; focusId: Uuid; title: string }`
  - Plan action variant gains `approved?: boolean; results?: PlanOperationResult[]`

- [ ] **Step 1: Create the submodule branch**

```bash
cd public && git checkout -b plot-twist-agent-harness && cd ..
```

- [ ] **Step 2: Add `PlanOperationResult` and extend the plan action variant**

In `public/twister/src/plot.ts`, directly above the `Action` type union, add:

```typescript
/**
 * Outcome of a single plan operation, reported back to the plan callback
 * after server-side execution. Order matches the plan's `operations` array.
 */
export type PlanOperationResult = { success: boolean; error?: string };
```

Replace the plan Action variant (currently lines 322-331) with:

```typescript
  | {
      /** Structured plan of operations for user approval */
      type: ActionType.plan;
      /** Human-readable summary of the plan */
      title: string;
      /** Operations to execute on approval */
      operations: PlanOperation[];
      /** Callback invoked with (action, approved: boolean) after the user decides */
      callback: Callback;
      /**
       * The user's decision. Set by the server when the action is delivered
       * to the plan callback; absent on the action the twist created.
       */
      approved?: boolean;
      /**
       * Per-operation execution results, same order as `operations`. Set by
       * the server when `approved` is true: operations are executed
       * server-side BEFORE the callback is invoked.
       */
      results?: PlanOperationResult[];
    };
```

- [ ] **Step 3: Add the `createFocus` operation variant**

In the `PlanOperation` union (`plot.ts:1305`), add as the first variant:

```typescript
  | {
      type: "createFocus";
      /**
       * Client-generated Uuid (Uuid.Generate()) so later operations in the
       * same plan can reference this focus before it exists. Execution
       * creates the focus with exactly this id.
       */
      focusId: Uuid;
      title: string;
    }
```

- [ ] **Step 4: Create the changeset**

Create `public/.changeset/plan-execution-contract.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `createFocus` plan operation, `approved`/`results` fields on plan actions, and `PlanOperationResult` — plan operations are now executed server-side when the user approves, and the plan callback receives `(action, approved)` with per-operation results on the action.
```

- [ ] **Step 5: Build and validate**

```bash
cd public/twister && pnpm build && cd .. && pnpm validate-changesets && cd ..
pnpm install
```

Expected: build succeeds, changeset valid, workspace link refreshed.

- [ ] **Step 6: Commit (submodule)**

```bash
cd public && git add twister/src/plot.ts .changeset/plan-execution-contract.md && git commit -m "feat(twister): plan execution contract — createFocus op, approved/results on plan actions" && cd ..
```

---

### Task 2: Server-side plan execution on approval (`workers/api`)

**Files:**
- Modify: `workers/api/src/twist/tools/plot/plan.ts` (rewrite `executePlan` for current op shapes; add `executeApprovedPlan`)
- Modify: `workers/api/src/twist/tools/callbacks.ts:148-179` (`HandleActionCallback` plan branch)
- Test: `workers/api/src/twist/tools/plot/plan.test.ts` (new; pure unit tests with a mocked Plot)

**Interfaces:**
- Consumes: Task 1's `PlanOperationResult`, `createFocus` variant. `invokeWebhookCallback(env, ctx, fullToken, ...args)`. `CallbacksState.validateAndLoad` / `LoadResult` (see `workers/api/src/twist/invoke-webhook.ts:59-70` for the stub pattern), `disposeRpc` from `../utils/rpc`, `createDb` from `../db`, `CallbackError` from `../errors`.
- Produces (used by Task 6's twist callback):
  - `executePlan(plot: Plot, operations: PlanOperation[]): Promise<PlanOperationResult[]>`
  - `executeApprovedPlan(env: Bindings, fullToken: string, operations: PlanOperation[]): Promise<PlanOperationResult[]>`
  - Runtime contract: on plan-action POST, server executes ops iff `approved === true`, sets `action.results`, then invokes the twist callback as `(action, approved)`; after a successful approved dispatch it deletes the callback token (replay guard). Rejected plans invoke the callback with `(action, false)` and leave the token live (user may approve later).

- [ ] **Step 1: Write failing unit tests for the rewritten `executePlan`**

Create `workers/api/src/twist/tools/plot/plan.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";
import type { PlanOperation } from "@plotday/twister/plot";

import { executePlan } from "./plan";
import type { Plot } from "./index";

function mockPlot() {
  return {
    twistInstanceId: "twist-1",
    updateThread: vi.fn().mockResolvedValue(undefined),
    updateLink: vi.fn().mockResolvedValue(undefined),
    createThread: vi.fn().mockResolvedValue({ id: "t-new" }),
    createNote: vi.fn().mockResolvedValue("n-new"),
    updateFocus: vi.fn().mockResolvedValue(undefined),
    createFocus: vi.fn().mockResolvedValue({ id: "f-new", created: true }),
  } as unknown as Plot;
}

describe("executePlan", () => {
  it("maps each current-shape operation to the right Plot call", async () => {
    const plot = mockPlot();
    const ops: PlanOperation[] = [
      { type: "createFocus", focusId: "f-1" as any, title: "Archive" },
      {
        type: "updateThread",
        threadId: "t-1" as any,
        threadTitle: "Old",
        changes: { archived: true, focus: { id: "f-1" as any, title: "Archive" } },
      },
      { type: "createThread", title: "New", focusId: "f-1" as any, focusTitle: "Archive" },
      { type: "createNote", threadId: "t-1" as any, threadTitle: "Old", content: "hi" },
      { type: "updateFocus", focusId: "f-2" as any, focusTitle: "Inbox", changes: { title: "In" } },
      { type: "updateLink", linkId: "l-1" as any, linkTitle: "Doc", changes: { threadId: "t-1" as any } },
    ];

    const results = await executePlan(plot, ops);

    expect(results).toEqual(Array(6).fill({ success: true }));
    expect(plot.createFocus).toHaveBeenCalledWith({ id: "f-1", title: "Archive" });
    expect(plot.updateThread).toHaveBeenCalledWith({
      id: "t-1",
      archived: true,
      focus: { id: "f-1" },
    });
    expect(plot.createThread).toHaveBeenCalledWith({ title: "New", focus: { id: "f-1" } });
    expect(plot.createNote).toHaveBeenCalledWith({ thread: { id: "t-1" }, content: "hi" });
    expect(plot.updateFocus).toHaveBeenCalledWith({ id: "f-2", title: "In" });
    expect(plot.updateLink).toHaveBeenCalledWith({ id: "l-1", threadId: "t-1" });
  });

  it("captures per-operation failures without aborting the batch", async () => {
    const plot = mockPlot();
    (plot.updateThread as any).mockRejectedValueOnce(new Error("boom"));
    const ops: PlanOperation[] = [
      { type: "updateThread", threadId: "t-1" as any, threadTitle: "A", changes: { archived: true } },
      { type: "createNote", threadId: "t-2" as any, threadTitle: "B", content: "ok" },
    ];

    const results = await executePlan(plot, ops);

    expect(results[0]).toEqual({ success: false, error: "boom" });
    expect(results[1]).toEqual({ success: true });
  });

  it("reports unknown operation types as failures", async () => {
    const results = await executePlan(mockPlot(), [{ type: "dropTables" } as any]);
    expect(results[0].success).toBe(false);
    expect(results[0].error).toContain("Unknown operation type");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd workers/api && pnpm vitest run src/twist/tools/plot/plan.test.ts
```

(If the package has multiple vitest configs, use whichever config runs sibling unit tests like `__tests__/plot.test.ts` — check `workers/api/package.json` scripts.)
Expected: FAIL — current `executePlan` calls `plot.updateThread({id, priority: ...})` (legacy shapes) and has no `createFocus`/`updateFocus` cases.

- [ ] **Step 3: Rewrite `executePlan` for current `PlanOperation` shapes**

Replace the body of `executePlan` in `workers/api/src/twist/tools/plot/plan.ts`:

```typescript
import type { PlanOperation, PlanOperationResult } from "@plotday/twister/plot";
import { createLogger } from "@plotday/worker-util";

import type { Plot } from "./index";

/**
 * Executes a batch of plan operations sequentially.
 *
 * Called when a user approves a plan action. Each operation is mapped to the
 * corresponding Plot tool method. `createFocus` operations should be ordered
 * first by the planner so later operations can reference the new focus ids.
 */
export async function executePlan(
  plot: Plot,
  operations: PlanOperation[]
): Promise<PlanOperationResult[]> {
  const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
  const results: PlanOperationResult[] = [];

  for (const op of operations) {
    try {
      switch (op.type) {
        case "createFocus": {
          await plot.createFocus({ id: op.focusId, title: op.title });
          results.push({ success: true });
          break;
        }
        case "updateThread": {
          const update: Record<string, unknown> = { id: op.threadId };
          if (op.changes.title !== undefined) update.title = op.changes.title;
          if (op.changes.archived !== undefined) update.archived = op.changes.archived;
          if (op.changes.type !== undefined) update.type = op.changes.type;
          if (op.changes.focus) update.focus = { id: op.changes.focus.id };
          await plot.updateThread(update as any);
          results.push({ success: true });
          break;
        }
        case "updateLink": {
          const linkUpdate: Record<string, unknown> = { id: op.linkId };
          if (op.changes.threadId !== undefined) linkUpdate.threadId = op.changes.threadId;
          await plot.updateLink(linkUpdate as any);
          results.push({ success: true });
          break;
        }
        case "createThread": {
          await plot.createThread({ title: op.title, focus: { id: op.focusId } });
          results.push({ success: true });
          break;
        }
        case "createNote": {
          await plot.createNote({ thread: { id: op.threadId }, content: op.content });
          results.push({ success: true });
          break;
        }
        case "updateFocus": {
          const focusUpdate: Record<string, unknown> = { id: op.focusId };
          if (op.changes.title !== undefined) focusUpdate.title = op.changes.title;
          if (op.changes.archived !== undefined) focusUpdate.archived = op.changes.archived;
          await plot.updateFocus(focusUpdate as any);
          results.push({ success: true });
          break;
        }
        default: {
          results.push({
            success: false,
            error: `Unknown operation type: ${(op as any).type}`,
          });
          break;
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logger.error(`Plan operation failed: ${op.type}`, error as Error);
      results.push({ success: false, error: message });
    }
  }

  return results;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd workers/api && pnpm vitest run src/twist/tools/plot/plan.test.ts
```

Expected: PASS (3 tests).

- [ ] **Step 5: Add `executeApprovedPlan`**

Append to `workers/api/src/twist/tools/plot/plan.ts` (add the new imports at top; keep static imports):

```typescript
import { FocusAccess, LinkAccess, ThreadAccess } from "@plotday/twister/tools/plot";

import { createDb } from "../../../db";
import type { Bindings } from "../../../env";
import { CallbackError } from "../../../errors";
import type { LoadResult } from "../../../state/callbacks";
import { disposeRpc } from "../../../utils/rpc";
import { Plot } from "./index";
```

(Adjust relative import depths to match the file's actual location — `plan.ts` sits at `workers/api/src/twist/tools/plot/`, so `../../../db` etc. Check neighboring files' imports and mirror them. `Plot` must switch from a type-only to a value import.)

```typescript
/**
 * Executes a user-approved plan for the twist that created it.
 *
 * Runs in the API worker on the `/callback/:token` request path — the
 * authenticated approval POST is the user's consent, so the Plot tool is
 * constructed with full admin access and WITHOUT `requireApproval` (the
 * gate exists to force plans; the plan was just approved).
 */
export async function executeApprovedPlan(
  env: Bindings,
  fullToken: string,
  operations: PlanOperation[]
): Promise<PlanOperationResult[]> {
  const [doIdHex] = fullToken.split(":");
  const callbacksStub = env.CALLBACKS.get(env.CALLBACKS.idFromString(doIdHex));
  let twistInstanceId: string;
  try {
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    const load = (await callbacksStub.validateAndLoad(fullToken)) as LoadResult;
    if ("__error" in load) {
      throw new CallbackError(load.type, load.context);
    }
    twistInstanceId = load.callback.twistInstanceId;
  } finally {
    disposeRpc(callbacksStub);
  }

  const db = createDb(env);
  try {
    const plot = new Plot({
      db,
      twistInstanceId,
      env,
      options: {
        thread: { access: ThreadAccess.Full },
        focus: { access: FocusAccess.Full },
        link: { access: LinkAccess.Full },
      },
    });
    return await executePlan(plot, operations);
  } finally {
    await db.destroy();
  }
}
```

Verify the exact `LoadResult`/`validateAndLoad` usage against `workers/api/src/twist/invoke-webhook.ts:59-70` and mirror it (including the `@ts-ignore`).

- [ ] **Step 6: Wire the plan branch into `HandleActionCallback`**

In `workers/api/src/twist/tools/callbacks.ts`, inside `HandleActionCallback`'s `try` (after the token-match check at line ~167), replace the plain `return await invokeWebhookCallback(env, ctx, callbackToken, action);` with:

```typescript
      if (action.type === ActionType.plan) {
        const approved = action.approved === true;
        if (approved && Array.isArray(action.operations) && action.operations.length > 0) {
          action.results = await executeApprovedPlan(env, token, action.operations);
        }
        const result = await invokeWebhookCallback(env, ctx, callbackToken, action, approved);
        if (approved) {
          // Replay guard: an approved plan is consumed. Rejections keep the
          // token live so the user can still approve later.
          const [doIdHex] = callbackToken.split(":");
          const stub = env.CALLBACKS.get(env.CALLBACKS.idFromString(doIdHex));
          try {
            await stub.delete(callbackToken);
          } catch {
            // best-effort cleanup
          } finally {
            disposeRpc(stub);
          }
        }
        return result;
      }

      return await invokeWebhookCallback(env, ctx, callbackToken, action);
```

Add imports: `executeApprovedPlan` from `../tools/plot/plan` (mirror existing relative style) and `disposeRpc` from `../../utils/rpc` if not present. If the plan Action type narrows poorly here (the `action` param may be typed as a broad `Action`), narrow with `action.type === ActionType.plan` and access `approved`/`results`/`operations` on the narrowed type from Task 1.

- [ ] **Step 7: Lint + full plot test file sweep**

```bash
cd workers/api && pnpm lint && pnpm vitest run src/twist/tools/plot/plan.test.ts
```

Expected: lint clean, tests PASS.

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/twist/tools/plot/plan.ts workers/api/src/twist/tools/plot/plan.test.ts workers/api/src/twist/tools/callbacks.ts
git commit -m "fix(twists): execute approved plan operations server-side and pass (action, approved) to plan callbacks"
```

---

### Task 3: Flutter plan-card rendering for current op shapes (`apps/plot`)

**Files:**
- Modify: `apps/plot/lib/store/user_action.dart:318-366` (`PlanOperation.description` getter)
- Test: `apps/plot/test/store/user_action_plan_test.dart` (new)

**Interfaces:**
- Consumes: plan-op JSON shapes from Task 1 (`createFocus {focusId,title}`, `updateThread.changes.focus {id,title}`, `createThread.focusTitle`, `updateFocus {focusId,focusTitle,changes}`).
- Produces: human-readable `description` strings rendered in `PlanActionWidget`. Keep the legacy `updatePriority`/`changes['priority']`/`priorityTitle` branches for old queued actions — add the new shapes alongside.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/store/user_action_plan_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/user_action.dart';

void main() {
  group('PlanOperation.description', () {
    test('createFocus renders title', () {
      final op = PlanOperation.fromJson({'type': 'createFocus', 'focusId': 'f1', 'title': 'Archive'});
      expect(op.description, 'Create focus "Archive"');
    });

    test('updateThread move-to-focus renders target focus', () {
      final op = PlanOperation.fromJson({
        'type': 'updateThread',
        'threadId': 't1',
        'threadTitle': 'Old thread',
        'changes': {
          'focus': {'id': 'f1', 'title': 'Archive'},
        },
      });
      expect(op.description, 'Update "Old thread": move to Archive');
    });

    test('updateFocus rename renders focus title', () {
      final op = PlanOperation.fromJson({
        'type': 'updateFocus',
        'focusId': 'f1',
        'focusTitle': 'Inbox',
        'changes': {'title': 'In'},
      });
      expect(op.description, 'Update focus "Inbox": rename');
    });

    test('createThread renders focusTitle', () {
      final op = PlanOperation.fromJson({
        'type': 'createThread',
        'title': 'New',
        'focusId': 'f1',
        'focusTitle': 'Archive',
      });
      expect(op.description, 'Create "New" in Archive');
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd apps/plot && flutter test test/store/user_action_plan_test.dart
```

Expected: FAIL — `createFocus`/`updateFocus` hit the `default:` branch; `changes['focus']` is ignored; `createThread` reads `priorityTitle` only.

- [ ] **Step 3: Extend the description getter**

In `apps/plot/lib/store/user_action.dart` `PlanOperation.description`:

- `createThread` case: read `focusTitle` first, fall back to `priorityTitle`:

```dart
      case 'createThread':
        final title = data['title'] as String? ?? 'Untitled';
        final focusTitle =
            data['focusTitle'] as String? ?? data['priorityTitle'] as String?;
        if (focusTitle != null) return 'Create "$title" in $focusTitle';
        return 'Create "$title"';
```

- `updateThread` case: after the existing `changes['priority']` branch, add:

```dart
        if (changes['focus'] != null) {
          final f = changes['focus'] as Map<String, dynamic>;
          parts.add('move to ${f['title'] ?? 'focus'}');
        }
```

- Add new cases before `default:`:

```dart
      case 'createFocus':
        final title = data['title'] as String? ?? 'Untitled';
        return 'Create focus "$title"';
      case 'updateFocus':
        final focusTitle = data['focusTitle'] as String? ?? 'focus';
        final changes = data['changes'] as Map<String, dynamic>? ?? {};
        final parts = <String>[];
        if (changes['title'] != null) parts.add('rename');
        if (changes['archived'] == true) parts.add('archive');
        if (changes['archived'] == false) parts.add('unarchive');
        if (parts.isEmpty) return 'Update focus "$focusTitle"';
        return 'Update focus "$focusTitle": ${parts.join(', ')}';
```

(Watch for variable-name collisions with the existing `updatePriority` case's locals — Dart switch cases share scope; wrap case bodies in `{}` blocks if needed, matching how the file already handles this.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/plot && flutter test test/store/user_action_plan_test.dart
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/user_action.dart apps/plot/test/store/user_action_plan_test.dart
git commit -m "fix(app): render current plan-operation shapes (focus moves, createFocus, updateFocus) in plan cards"
```

---

### Task 4: Twist module split + vitest setup (`twists/plot`, no behavior change)

**Files:**
- Create: `twists/plot/src/prompt.ts`, `twists/plot/src/messages.ts`, `twists/plot/src/actions.ts`
- Modify: `twists/plot/src/index.ts` (remove moved code, import from modules), `twists/plot/package.json` (vitest)
- Test: `twists/plot/src/messages.test.ts`, `twists/plot/src/actions.test.ts`

**Interfaces:**
- Produces (used by every later task):
  - `prompt.ts`: `export const SYSTEM_PROMPT: string` (verbatim move of `index.ts:23-41` for now; rewritten in Task 5)
  - `messages.ts`: `export type ChatMessage = { role: "user" | "assistant"; content: string };` and `export function buildMessages(notes: Note[]): ChatMessage[]` (verbatim logic move of `index.ts:261-288`; extended in Task 9)
  - `actions.ts`: `export function buildActions(threadIds: Set<string>, currentThreadId: string, sources?: AISource[]): Action[]` (verbatim move of `index.ts:291-319`)

- [ ] **Step 1: Add vitest**

In `twists/plot/package.json` add `"test": "vitest run"` to scripts and `"vitest": "^3.0.0"` (match the version other workspace packages use — check `workers/api/package.json`) to `devDependencies`. Run `pnpm install`.

- [ ] **Step 2: Create the three modules**

Move code verbatim (adjust imports):
- `prompt.ts`: the `SYSTEM_PROMPT` template literal from `index.ts:23-41`, exported.
- `messages.ts`: `buildMessages` from `index.ts:261-288` as a top-level exported function taking `notes: Note[]`; import `ActorType`, `type Note` from `@plotday/twister`. Export the `ChatMessage` type and use it as the return type.
- `actions.ts`: `buildActions` from `index.ts:291-319` as a top-level exported function; imports `type Action, ActionType, type Uuid` from `@plotday/twister` and `type AISource` from `@plotday/twister/tools/ai`.

Update `index.ts` to import all three and delete the private methods (call sites: `this.buildMessages(...)` → `buildMessages(...)`, etc.).

- [ ] **Step 3: Write module tests**

`twists/plot/src/messages.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { ActorType, type Note } from "@plotday/twister";

import { buildMessages } from "./messages";

function note(author: ActorType, content: string): Note {
  return { content, author: { type: author } } as unknown as Note;
}

describe("buildMessages", () => {
  it("maps twist notes to assistant and others to user", () => {
    const out = buildMessages([note(ActorType.User, "hi"), note(ActorType.Twist, "hello")]);
    expect(out).toEqual([
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
    ]);
  });

  it("merges consecutive same-role turns", () => {
    const out = buildMessages([
      note(ActorType.User, "a"),
      note(ActorType.User, "b"),
      note(ActorType.Twist, "c"),
    ]);
    expect(out).toEqual([
      { role: "user", content: "a\n\nb" },
      { role: "assistant", content: "c" },
    ]);
  });

  it("drops leading assistant turns and empty notes", () => {
    const out = buildMessages([
      note(ActorType.Twist, "welcome"),
      note(ActorType.User, "  "),
      note(ActorType.User, "question"),
    ]);
    expect(out).toEqual([{ role: "user", content: "question" }]);
  });
});
```

`twists/plot/src/actions.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { ActionType } from "@plotday/twister";

import { buildActions } from "./actions";

describe("buildActions", () => {
  it("caps thread actions at 3 and skips the current thread", () => {
    const ids = new Set(["cur", "a", "b", "c", "d"]);
    const actions = buildActions(ids, "cur");
    expect(actions).toHaveLength(3);
    expect(actions.every((a) => a.type === ActionType.thread)).toBe(true);
  });

  it("adds up to 5 url sources as external actions", () => {
    const sources = Array.from({ length: 7 }, (_, i) => ({
      type: "source" as const,
      sourceType: "url" as const,
      id: `s${i}`,
      url: `https://x.test/${i}`,
      title: `S${i}`,
    }));
    const actions = buildActions(new Set(), "cur", sources as any);
    expect(actions).toHaveLength(5);
    expect(actions[0]).toMatchObject({ type: ActionType.external, url: "https://x.test/0" });
  });
});
```

- [ ] **Step 4: Run tests and lint**

```bash
cd twists/plot && pnpm test && pnpm lint
```

Expected: 5 tests PASS; lint clean (lint runs `plot lint` — TypeScript build must succeed, proving `index.ts` still compiles against the extracted modules).

- [ ] **Step 5: Commit**

```bash
git add twists/plot
git commit -m "refactor(plot-twist): split prompt/messages/actions into modules and add vitest"
```

---

### Task 5: Chainable, workspace-wide tool surface (`twists/plot`)

**Files:**
- Create: `twists/plot/src/tools.ts`
- Modify: `twists/plot/src/prompt.ts` (rewrite SYSTEM_PROMPT), `twists/plot/src/index.ts` (use `buildAgentTools`)
- Test: `twists/plot/src/tools.test.ts`

**Interfaces:**
- Consumes: Task 4 modules.
- Produces (used by Tasks 6-10):

```typescript
// tools.ts
export type AgentToolContext = {
  plot: Plot; // this.tools.plot (the RPC stub satisfies the abstract class type)
  currentFocusId: Uuid;
  currentThreadId: string;
  referencedThreadIds: Set<string>;
  /** Progress sink; wired in Task 8. No-op default. */
  onProgress: (message: string) => Promise<void>;
  /** Posts a plan card; wired in Task 6. Returns status text for the model. */
  proposePlan: (request: string, rawOperations: unknown) => Promise<string>;
};
export function buildAgentTools(ctx: AgentToolContext): Record<string, unknown>;
export function truncateText(s: string | null | undefined, max: number): string | null;
export function formatThreadNotes(
  notes: Array<{ author: string; content: string }>,
  perNoteMax?: number, // default 2000
  totalMax?: number // default 15000
): { notes: Array<{ author: string; content: string }>; truncated: boolean; totalNotes: number };
```

- [ ] **Step 1: Write failing tests for the pure helpers**

`twists/plot/src/tools.test.ts`:

```typescript
import { describe, expect, it } from "vitest";

import { formatThreadNotes, truncateText } from "./tools";

describe("truncateText", () => {
  it("passes through short text and null", () => {
    expect(truncateText("short", 10)).toBe("short");
    expect(truncateText(null, 10)).toBeNull();
  });
  it("truncates with ellipsis marker", () => {
    const out = truncateText("x".repeat(50), 10)!;
    expect(out.length).toBeLessThan(30);
    expect(out).toContain("…");
  });
});

describe("formatThreadNotes", () => {
  it("caps each note and the total budget", () => {
    const notes = Array.from({ length: 20 }, (_, i) => ({
      author: "user",
      content: "y".repeat(3000),
    }));
    const out = formatThreadNotes(notes, 2000, 15000);
    expect(out.totalNotes).toBe(20);
    expect(out.truncated).toBe(true);
    expect(out.notes.length).toBeLessThan(20);
    for (const n of out.notes) expect(n.content.length).toBeLessThanOrEqual(2001);
  });
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd twists/plot && pnpm test
```

Expected: FAIL — `./tools` does not exist.

- [ ] **Step 3: Implement `tools.ts`**

```typescript
import { Type } from "typebox";

import { ActorType, type Uuid } from "@plotday/twister";
import type { Plot } from "@plotday/twister/tools/plot";

export type AgentToolContext = {
  plot: Plot;
  currentFocusId: Uuid;
  currentThreadId: string;
  referencedThreadIds: Set<string>;
  onProgress: (message: string) => Promise<void>;
  proposePlan: (request: string, rawOperations: unknown) => Promise<string>;
};

export function truncateText(s: string | null | undefined, max: number): string | null {
  if (s == null) return null;
  if (s.length <= max) return s;
  return s.slice(0, max) + "…";
}

export function formatThreadNotes(
  notes: Array<{ author: string; content: string }>,
  perNoteMax = 2000,
  totalMax = 15000
): { notes: Array<{ author: string; content: string }>; truncated: boolean; totalNotes: number } {
  const out: Array<{ author: string; content: string }> = [];
  let budget = totalMax;
  let truncated = false;
  for (const n of notes) {
    const content = truncateText(n.content, perNoteMax)!;
    if (content !== n.content) truncated = true;
    if (content.length > budget) {
      truncated = true;
      break;
    }
    budget -= content.length;
    out.push({ author: n.author, content });
  }
  return { notes: out, truncated, totalNotes: notes.length };
}

export function buildAgentTools(ctx: AgentToolContext): Record<string, unknown> {
  return {
    searchPlotData: {
      description:
        "Semantically search the user's ENTIRE workspace (all focuses) — notes, threads, and links. Returns threadId for each hit so you can follow up with readThreadNotes. Pass focusId (from listFocuses) to narrow to one focus. Call this FIRST whenever the answer could involve the user's own content.",
      inputSchema: Type.Object({
        query: Type.String({ description: "What to search for." }),
        focusId: Type.Optional(
          Type.String({ description: "Limit to one focus. Omit to search everything." })
        ),
      }),
      execute: async ({ query, focusId }: { query: string; focusId?: string }) => {
        await ctx.onProgress(`Searching your workspace for “${query}”…`);
        const results = await ctx.plot.search(query, {
          focusId: focusId as Uuid | undefined,
          limit: 10,
        });
        for (const r of results) {
          if (r.thread?.id) ctx.referencedThreadIds.add(r.thread.id);
        }
        return results.map((r) => ({
          threadId: r.thread.id,
          kind: r.type,
          title: r.thread.title ?? (r.type === "link" ? r.title : null),
          focus: r.focus.title ?? null,
          content: truncateText(r.content ?? (r.type === "link" ? r.title : null), 700),
          url: r.type === "link" ? r.sourceUrl ?? null : null,
        }));
      },
    },
    listThreads: {
      description:
        "List threads in a focus (default: the current focus). Returns id, title, archived, focus. Use offset to page through more than 50.",
      inputSchema: Type.Object({
        focusId: Type.Optional(Type.String({ description: "Focus id from listFocuses. Defaults to the current focus." })),
        includeArchived: Type.Optional(Type.Boolean({ description: "Include archived threads (default false)." })),
        offset: Type.Optional(Type.Number({ description: "Pagination offset (default 0)." })),
      }),
      execute: async ({
        focusId,
        includeArchived,
        offset,
      }: {
        focusId?: string;
        includeArchived?: boolean;
        offset?: number;
      }) => {
        const threads = await ctx.plot.getThreads({
          focusId: (focusId as Uuid | undefined) ?? ctx.currentFocusId,
          includeArchived: includeArchived ?? false,
          limit: 50,
          offset: offset ?? 0,
        });
        return threads.map((t) => ({
          id: t.id,
          title: t.title,
          archived: t.archived,
          focus: t.focus.title,
        }));
      },
    },
    listFocuses: {
      description: "List the user's focuses (projects/folders) with their ids.",
      inputSchema: Type.Object({}),
      execute: async () => {
        const focuses = await ctx.plot.getFocuses();
        return focuses.map((p) => ({ id: p.id, title: p.title }));
      },
    },
    readThreadNotes: {
      description:
        "Read the conversation of a specific thread by id (from searchPlotData or listThreads). Long threads are truncated.",
      inputSchema: Type.Object({
        threadId: Type.String({ description: "The thread id to read." }),
      }),
      execute: async ({ threadId }: { threadId: string }) => {
        const target = await ctx.plot.getThread({ id: threadId as Uuid });
        if (!target) return { error: "Thread not found." };
        ctx.referencedThreadIds.add(target.id);
        await ctx.onProgress(`Reading “${target.title ?? "thread"}”…`);
        const notes = await ctx.plot.getNotes(target);
        const mapped = notes
          .filter((n) => n.content?.trim())
          .map((n) => ({
            author: n.author.type === ActorType.Twist ? "assistant" : "user",
            content: n.content as string,
          }));
        const formatted = formatThreadNotes(mapped);
        return { title: target.title, ...formatted };
      },
    },
    proposeOperations: {
      description:
        "Propose a reorganization plan (move/archive/rename/create threads and focuses). The plan is shown to the user for approval — NOTHING changes until they approve. Only use when the user explicitly asks to reorganize.",
      inputSchema: Type.Object({
        request: Type.String({
          description: "The organization request in the user's words, e.g. 'archive all done threads'.",
        }),
      }),
      execute: async ({ request }: { request: string }) => {
        await ctx.onProgress("Drafting a reorganization plan…");
        return await ctx.proposePlan(request, null);
      },
    },
  };
}
```

- [ ] **Step 4: Rewrite `SYSTEM_PROMPT` in `prompt.ts`**

```typescript
export const SYSTEM_PROMPT = `You are Plot's built-in AI assistant. You are a capable, general-purpose assistant — answer any question or carry out any request the way a frontier chat assistant would, while also being deeply integrated with the user's Plot workspace.

You have tools:
- searchPlotData: semantically search the user's ENTIRE workspace (all focuses) — notes, threads, and links. Each hit includes a threadId.
- readThreadNotes: read a specific thread's conversation by threadId (use the ids returned by searchPlotData or listThreads).
- listFocuses / listThreads: browse the user's focuses (projects/folders) and the threads in a focus.
- proposeOperations: propose a plan to move, archive, rename, or create threads and focuses. The plan is shown to the user for approval — nothing changes until they approve. Only use it when the user explicitly asks to reorganize.
- Web search is available for up-to-date, real-world information. It is a supplement to searchPlotData, never a substitute for it.

Tool-use rules:
- searchPlotData is your DEFAULT first move. Before answering any question whose answer could plausibly be informed by the user's own content, call searchPlotData FIRST. This includes anything about their notes, threads, tasks, meetings, events, appointments, people, projects, decisions, plans, status, or history — and anything phrased with "my"/"our"/"we"/"I", or naming a specific person, project, company, date, or thing the user would have recorded.
- To dig deeper into a search hit, call readThreadNotes with its threadId.
- When you are unsure whether the answer lives in the user's workspace, search it. A needless Plot search is cheap; a missed one means a wrong or generic answer.
- Only skip searchPlotData for requests that are purely general knowledge, creative writing, or external real-world facts with no plausible connection to the user's data.
- If a question could depend on BOTH the user's data and external facts, search Plot first, then web — and reconcile the two in your answer (the user's own content takes precedence when they conflict).
- Never claim to have looked at the user's data unless you actually called searchPlotData (or another data tool).
- Be concise and direct. Use Markdown (headings, lists, tables, fenced code blocks with a language) when it helps.
- When you propose a plan via proposeOperations, don't repeat the full plan in your reply — the plan card is shown separately for approval.
- If asked what you can do, explain these capabilities in a friendly sentence or two.`;
```

- [ ] **Step 5: Wire into `index.ts`**

In `respond()`, replace the inline `tools: { ... } as any` block with:

```typescript
      const toolCtx: AgentToolContext = {
        plot: this.tools.plot,
        currentFocusId: note.thread.focus.id,
        currentThreadId: thread.id,
        referencedThreadIds,
        onProgress: async () => {}, // wired in Task 8
        proposePlan: async (request) => await this.buildAndPostPlan(note, request),
      };
      // Cast to `any` to avoid TS2589 (deep generic instantiation) from the
      // large inline tool set; tool shapes are validated at runtime.
      const agentTools = buildAgentTools(toolCtx) as any;
```

and pass `tools: agentTools` to `prompt()`. Keep `buildAndPostPlan` as-is for now (replaced in Task 6). Remove the now-dead inline `organizeContent` tool.

- [ ] **Step 6: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): chainable workspace-wide tool surface — ids in search hits, focusId params, pagination, truncation"
```

---

### Task 6: Planner-in-loop with deferred focus creation + honest plan reporting (`twists/plot`)

**Files:**
- Create: `twists/plot/src/planner.ts`
- Modify: `twists/plot/src/index.ts` (replace `buildAndPostPlan` internals; new `onPlanResponse`)
- Test: `twists/plot/src/planner.test.ts`

**Interfaces:**
- Consumes: Task 1 contract (`createFocus` op, `approved`/`results` on the action), Task 5's `proposePlan` hook, `ChatMessage` from Task 4.
- Produces:

```typescript
// planner.ts
export const OPERATIONS_SCHEMA: /* Typebox array schema — AI-facing */;
export type RawOperation = Static<typeof OPERATIONS_SCHEMA>[number];
export const PLANNER_SYSTEM_PROMPT: string;
export function buildPlannerPrompt(args: {
  request: string;
  conversation: ChatMessage[]; // last ~10 merged turns
  threads: Thread[];
  focuses: Focus[];
}): string;
export function validateOperations(
  raw: RawOperation[],
  threads: Array<{ id: string }>,
  focuses: Array<{ id: string }>,
  generateId: () => Uuid
): PlanOperation[];
export function describeOperation(op: PlanOperation): string;
export function summarizeOperations(ops: PlanOperation[]): string;
```

- Twist callback contract change: `onPlanResponse(action: Action, approved: boolean, threadId: string)` — server (Task 2) passes `(action, approved)`, curried `threadId` arrives third.

- [ ] **Step 1: Write failing tests for `validateOperations` + `describeOperation`**

`twists/plot/src/planner.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import type { Uuid } from "@plotday/twister";

import { describeOperation, summarizeOperations, validateOperations } from "./planner";

const threads = [{ id: "t-1" }, { id: "t-2" }];
const focuses = [{ id: "f-1" }];
let n = 0;
const genId = () => `new-${++n}` as Uuid;

describe("validateOperations", () => {
  it("drops ops referencing unknown thread/focus ids", () => {
    const ops = validateOperations(
      [
        { type: "updateThread", threadId: "ghost", threadTitle: "?", changes: { archived: true } },
        { type: "updateThread", threadId: "t-1", threadTitle: "A", changes: { archived: true } },
        { type: "updateFocus", focusId: "ghost", focusTitle: "?", changes: { title: "X" } },
      ] as any,
      threads,
      focuses,
      genId
    );
    expect(ops).toHaveLength(1);
    expect(ops[0]).toMatchObject({ type: "updateThread", threadId: "t-1" });
  });

  it("assigns ids to createFocus ops, orders them first, and remaps moves by title", () => {
    const ops = validateOperations(
      [
        {
          type: "updateThread",
          threadId: "t-1",
          threadTitle: "A",
          changes: { focus: { id: "", title: "Archive 2025" } },
        },
        { type: "createFocus", title: "Archive 2025" },
        { type: "createThread", title: "Index", focusId: "", focusTitle: "Archive 2025" },
      ] as any,
      threads,
      focuses,
      genId
    );
    expect(ops[0].type).toBe("createFocus");
    const focusId = (ops[0] as any).focusId;
    expect(focusId).toMatch(/^new-/);
    expect((ops[1] as any).changes.focus.id).toBe(focusId);
    expect((ops[2] as any).focusId).toBe(focusId);
  });

  it("caps at 50 operations", () => {
    const many = Array.from({ length: 60 }, (_, i) => ({
      type: "createNote",
      threadId: "t-1",
      threadTitle: "A",
      content: `note ${i}`,
    }));
    expect(validateOperations(many as any, threads, focuses, genId)).toHaveLength(50);
  });
});

describe("describeOperation / summarizeOperations", () => {
  it("describes createFocus and focus moves", () => {
    expect(
      describeOperation({ type: "createFocus", focusId: "f" as Uuid, title: "Archive" })
    ).toContain("Create focus");
    const summary = summarizeOperations([
      {
        type: "updateThread",
        threadId: "t-1" as Uuid,
        threadTitle: "A",
        changes: { focus: { id: "f-1" as Uuid, title: "Archive" } },
      },
    ]);
    expect(summary).toContain("Move **A** to **Archive**");
  });
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd twists/plot && pnpm test
```

Expected: FAIL — `./planner` does not exist.

- [ ] **Step 3: Implement `planner.ts`**

```typescript
import { Type, type Static } from "typebox";

import type { Focus, PlanOperation, Thread, Uuid } from "@plotday/twister";

import type { ChatMessage } from "./messages";

/** AI-facing schema: createFocus carries only a title — ids are assigned during validation. */
export const OPERATIONS_SCHEMA = Type.Array(
  Type.Union([
    Type.Object({
      type: Type.Literal("updateThread"),
      threadId: Type.String(),
      threadTitle: Type.String(),
      changes: Type.Object({
        archived: Type.Optional(Type.Boolean()),
        title: Type.Optional(Type.String()),
        type: Type.Optional(Type.String()),
        focus: Type.Optional(Type.Object({ id: Type.String(), title: Type.String() })),
      }),
    }),
    Type.Object({
      type: Type.Literal("createThread"),
      title: Type.String(),
      focusId: Type.String(),
      focusTitle: Type.String(),
    }),
    Type.Object({
      type: Type.Literal("createNote"),
      threadId: Type.String(),
      threadTitle: Type.String(),
      content: Type.String(),
    }),
    Type.Object({
      type: Type.Literal("updateFocus"),
      focusId: Type.String(),
      focusTitle: Type.String(),
      changes: Type.Object({
        title: Type.Optional(Type.String()),
        archived: Type.Optional(Type.Boolean()),
      }),
    }),
    Type.Object({
      type: Type.Literal("createFocus"),
      title: Type.String(),
    }),
  ])
);

export type RawOperation = Static<typeof OPERATIONS_SCHEMA>[number];

export const PLANNER_SYSTEM_PROMPT =
  "You are an organizational assistant for a workspace. The user wants to reorganize their content.\n\n" +
  "Given the conversation, the user's request, and the available data, produce a JSON array of operations.\n\n" +
  "Available operation types:\n" +
  "- updateThread: Change a thread's title, archived status, or move it to a different focus. Use changes.focus with {id, title} to move. Set changes.archived to true to archive.\n" +
  "- createThread: Create a new thread in a specific focus.\n" +
  "- createNote: Add a note to an existing thread.\n" +
  "- updateFocus: Rename a focus or archive it.\n" +
  "- createFocus: Create a new focus. Use this when the user asks to move threads to a focus that doesn't exist yet; reference it from other operations by its exact title (leave their focus id empty). Focuses are flat — they have no parent.\n\n" +
  "Rules:\n" +
  "- Only reference thread IDs and focus IDs from the provided data (except titles of focuses you create with createFocus).\n" +
  "- Include the current title in threadTitle/focusTitle fields for display purposes.\n" +
  "- Be conservative: only include operations that clearly match the user's request.\n" +
  "- Tag changes are not supported. If the user asks about tags, return an empty array.\n" +
  "- Only active (non-archived) threads are included in the list below. Already-archived threads cannot be targeted.\n" +
  "- Return an empty array if the request doesn't match any actionable operations.";

export function buildPlannerPrompt(args: {
  request: string;
  conversation: ChatMessage[];
  threads: Thread[];
  focuses: Focus[];
}): string {
  const conversationContext = args.conversation
    .slice(-10)
    .map((m) => `${m.role === "assistant" ? "Assistant" : "User"}: ${m.content}`)
    .join("\n");
  const threadsContext = args.threads
    .map(
      (t) =>
        `${t.id} | ${t.title} | Focus: ${t.focus.title} (${t.focus.id}) | Archived: ${
          t.archived ? "yes" : "no"
        }`
    )
    .join("\n");
  const focusesContext = args.focuses.map((p) => `${p.id} | ${p.title}`).join("\n");
  return (
    `Recent conversation:\n${conversationContext}\n\n` +
    `Request: ${args.request}\n\n` +
    `Threads (${args.threads.length}):\n${threadsContext}\n\n` +
    `Focuses (${args.focuses.length}):\n${focusesContext}`
  );
}

const MAX_OPERATIONS = 50;

/**
 * Validates AI-proposed operations against known ids, assigns explicit ids
 * to new focuses (createFocus ordered first), and remaps title-references
 * to those ids. Pure — focus creation is deferred to server-side execution.
 */
export function validateOperations(
  raw: RawOperation[],
  threads: Array<{ id: string }>,
  focuses: Array<{ id: string }>,
  generateId: () => Uuid
): PlanOperation[] {
  const threadIds = new Set(threads.map((t) => t.id));
  const focusIds = new Set(focuses.map((f) => f.id));

  const newFocusByTitle = new Map<string, { focusId: Uuid; title: string }>();
  const createFocusOps: PlanOperation[] = [];
  for (const op of raw) {
    if (op.type !== "createFocus") continue;
    const key = op.title.toLowerCase();
    if (newFocusByTitle.has(key)) continue;
    const entry = { focusId: generateId(), title: op.title };
    newFocusByTitle.set(key, entry);
    createFocusOps.push({ type: "createFocus", focusId: entry.focusId, title: entry.title });
  }

  const rest: PlanOperation[] = [];
  for (const op of raw) {
    if (op.type === "createFocus") continue;

    if (op.type === "updateThread") {
      if (!threadIds.has(op.threadId)) continue;
      if (op.changes.focus) {
        const created = newFocusByTitle.get(op.changes.focus.title.toLowerCase());
        if (created) {
          op.changes.focus = { id: created.focusId, title: created.title };
        } else if (!focusIds.has(op.changes.focus.id)) {
          continue;
        }
      }
      rest.push(op as PlanOperation);
    } else if (op.type === "createThread") {
      const created = newFocusByTitle.get(op.focusTitle.toLowerCase());
      if (created) {
        op.focusId = created.focusId;
        op.focusTitle = created.title;
      } else if (!focusIds.has(op.focusId)) {
        continue;
      }
      rest.push(op as PlanOperation);
    } else if (op.type === "createNote") {
      if (!threadIds.has(op.threadId)) continue;
      rest.push(op as PlanOperation);
    } else if (op.type === "updateFocus") {
      if (!focusIds.has(op.focusId)) continue;
      rest.push(op as PlanOperation);
    }
  }

  // Drop createFocus ops nothing references (avoid approving empty focuses).
  const referenced = new Set<string>();
  for (const op of rest) {
    if (op.type === "updateThread" && op.changes.focus) referenced.add(op.changes.focus.id);
    if (op.type === "createThread") referenced.add(op.focusId);
  }
  const keptCreates = createFocusOps.filter((op) =>
    op.type === "createFocus" ? referenced.has(op.focusId) : true
  );

  return [...keptCreates, ...rest].slice(0, MAX_OPERATIONS);
}

export function describeOperation(op: PlanOperation): string {
  switch (op.type) {
    case "createFocus":
      return `Create focus **${op.title}**`;
    case "updateThread":
      if (op.changes.focus) return `Move **${op.threadTitle}** to **${op.changes.focus.title}**`;
      if (op.changes.archived) return `Archive **${op.threadTitle}**`;
      if (op.changes.title) return `Rename **${op.threadTitle}** to **${op.changes.title}**`;
      return `Update **${op.threadTitle}**`;
    case "createThread":
      return `Create thread **${op.title}** in **${op.focusTitle}**`;
    case "createNote":
      return `Add note to **${op.threadTitle}**`;
    case "updateFocus":
      if (op.changes.archived) return `Archive focus **${op.focusTitle}**`;
      if (op.changes.title) return `Rename focus **${op.focusTitle}** to **${op.changes.title}**`;
      return `Update focus **${op.focusTitle}**`;
    case "updateLink":
      return `Move **${op.linkTitle}**`;
    default:
      return "Unknown operation";
  }
}

export function summarizeOperations(ops: PlanOperation[]): string {
  return ops.map((op) => `- ${describeOperation(op)}`).join("\n");
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd twists/plot && pnpm test
```

Expected: PASS.

- [ ] **Step 5: Rewire `buildAndPostPlan` in `index.ts`**

Replace the method with (keep the name; it's the `proposePlan` hook target). Uses `Uuid` generation — check what `@plotday/twister` exports for id generation (`Uuid.Generate()` per `NewFocus` docs); if unavailable in the twist runtime, use `crypto.randomUUID() as Uuid`.

```typescript
  /**
   * Compose an organization plan on a capable model (Gemini Pro) with
   * conversation context, validate it, and post it as a plan card. Focus
   * creation is DEFERRED into the plan — nothing mutates until approval.
   */
  private async buildAndPostPlan(note: Note, request: string): Promise<string> {
    const [threads, focuses, previousNotes] = await Promise.all([
      this.tools.plot.getThreads({ focusId: note.thread.focus.id, limit: 200 }),
      this.tools.plot.getFocuses(),
      this.tools.plot.getNotes(note.thread),
    ]);

    if (threads.length === 0) {
      return "There are no threads in this focus to organize.";
    }

    const response = await this.tools.ai.prompt({
      // Structured planning runs on the capable tier (Gemini Pro).
      model: { speed: "capable", cost: "high" },
      system: PLANNER_SYSTEM_PROMPT,
      prompt: buildPlannerPrompt({
        request,
        conversation: buildMessages(previousNotes),
        threads,
        focuses,
      }),
      outputSchema: OPERATIONS_SCHEMA,
    });

    const raw = response.output;
    if (!raw || raw.length === 0) {
      return "I couldn't determine any operations for that request.";
    }

    const operations = validateOperations(
      raw,
      threads,
      focuses,
      () => crypto.randomUUID() as Uuid
    );
    if (operations.length === 0) {
      return "I couldn't find any matching content to act on.";
    }

    const cb = await this.actionCallback(this.onPlanResponse, note.thread.id as string);
    const planAction = this.tools.plot.createPlan({
      title: `Organize: ${request.slice(0, 80)}`,
      operations,
      callback: cb,
    });

    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `Here's my plan (${operations.length} operation${
        operations.length === 1 ? "" : "s"
      }):\n\n${summarizeOperations(operations)}`,
      actions: [planAction],
    });

    return `Created a plan with ${operations.length} operation${
      operations.length === 1 ? "" : "s"
    }, shown above for the user's approval.`;
  }
```

Note the scoping decision: plan context stays scoped to the current focus's threads (`focusId: note.thread.focus.id`) — reorganization is a focus-local activity by default; the model can name other focuses via `listFocuses` data in conversation. This matches the tool description ("Only use when the user explicitly asks to reorganize").

- [ ] **Step 6: Rewrite `onPlanResponse` for the `(action, approved, threadId)` contract**

```typescript
  /**
   * Plan decision callback. The server executes approved operations BEFORE
   * invoking this (results ride on the action); rejections just invoke it
   * with approved=false.
   */
  async onPlanResponse(action: Action, approved: boolean, threadId: string): Promise<void> {
    if (action.type !== ActionType.plan) return;

    if (!approved) {
      await this.tools.plot.createNote({
        thread: { id: threadId as Uuid },
        content: "Okay — I won't make those changes.",
      });
      return;
    }

    const results = action.results ?? [];
    const failures = results
      .map((r, i) => ({ result: r, op: action.operations[i] }))
      .filter((x) => !x.result.success);

    const content =
      failures.length === 0
        ? `Done — completed all ${results.length} operation${results.length === 1 ? "" : "s"}.`
        : `Completed ${results.length - failures.length} of ${results.length} operations. These failed:\n\n` +
          failures
            .map((f) => `- ${describeOperation(f.op)} — ${f.result.error ?? "unknown error"}`)
            .join("\n");

    await this.tools.plot.createNote({
      thread: { id: threadId as Uuid },
      content,
    });
  }
```

- [ ] **Step 7: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): planner-in-loop on Gemini Pro with conversation context, deferred focus creation, honest per-op plan reporting"
```

---

### Task 7: Budget-aware looping + transient retry (`twists/plot`)

**Files:**
- Create: `twists/plot/src/retry.ts`
- Modify: `twists/plot/src/index.ts` (`respond()`: maxSteps, finishReason handling, continuation)
- Test: `twists/plot/src/retry.test.ts`

**Interfaces:**
- Consumes: `AIResponse.finishReason`, `response.response?.messages` (AIMessage[]), Task 5 tools.
- Produces:
  - `export function isTransientAiError(e: unknown): boolean`
  - `export async function promptWithRetry(ai: AI, request: Parameters<AI["prompt"]>[0], retryDelayMs?: number): ReturnType<AI["prompt"]>`
  - `respond()` behavior: main turn fast/high `maxSteps: 16`; if `finishReason === "tool-calls"`, ONE continuation on capable/high (`maxSteps: 8`) with prior tool transcript + a wrap-up nudge; `"length"` appends a truncation notice.

- [ ] **Step 1: Failing tests for `isTransientAiError`**

`twists/plot/src/retry.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";

import { isTransientAiError, promptWithRetry } from "./retry";

describe("isTransientAiError", () => {
  it.each([
    "429 Too Many Requests",
    "rate limit exceeded",
    "model is overloaded",
    "Request timeout",
    "fetch failed",
    "internal server error (500)",
    "503 Service Unavailable",
  ])("classifies '%s' as transient", (msg) => {
    expect(isTransientAiError(new Error(msg))).toBe(true);
  });

  it("does not classify logic errors as transient", () => {
    expect(isTransientAiError(new Error("No model available for provider"))).toBe(false);
    expect(isTransientAiError(new Error("AI features are disabled by the user."))).toBe(false);
  });
});

describe("promptWithRetry", () => {
  it("retries once on transient failure", async () => {
    const prompt = vi
      .fn()
      .mockRejectedValueOnce(new Error("overloaded"))
      .mockResolvedValueOnce({ text: "ok" });
    const out = await promptWithRetry({ prompt } as any, { messages: [] } as any, 1);
    expect(out.text).toBe("ok");
    expect(prompt).toHaveBeenCalledTimes(2);
  });

  it("rethrows non-transient errors immediately", async () => {
    const prompt = vi.fn().mockRejectedValue(new Error("bad schema"));
    await expect(promptWithRetry({ prompt } as any, {} as any, 1)).rejects.toThrow("bad schema");
    expect(prompt).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run to verify failure, then implement `retry.ts`**

```typescript
import type { AI } from "@plotday/twister/tools/ai";

const TRANSIENT_PATTERN =
  /\b429\b|\b5\d{2}\b|rate.?limit|overloaded|timeout|timed out|fetch failed|ECONNRESET|network|unavailable/i;

export function isTransientAiError(e: unknown): boolean {
  const message = e instanceof Error ? e.message : String(e);
  return TRANSIENT_PATTERN.test(message);
}

/** One retry on transient provider errors; everything else propagates. */
export async function promptWithRetry(
  ai: Pick<AI, "prompt">,
  request: Parameters<AI["prompt"]>[0],
  retryDelayMs = 1500
): Promise<Awaited<ReturnType<AI["prompt"]>>> {
  try {
    return await ai.prompt(request);
  } catch (error) {
    if (!isTransientAiError(error)) throw error;
    await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    return await ai.prompt(request);
  }
}
```

Run `pnpm test` — expected PASS.

- [ ] **Step 3: Continuation in `respond()`**

In `index.ts`, replace the single `prompt()` call with:

```typescript
      const baseRequest = {
        system: SYSTEM_PROMPT,
        webSearch: canWebSearch,
        tools: agentTools,
      };

      let response = await promptWithRetry(this.tools.ai, {
        ...baseRequest,
        // Plot-funded → Gemini Flash for conversational turns.
        model: { speed: "fast", cost: "high" },
        messages,
        maxSteps: 16,
      } as any);

      if (response.finishReason === "tool-calls") {
        // Step budget exhausted mid-chain: one continuation on the capable
        // tier (Gemini Pro) with the tool transcript carried forward.
        const transcript = response.response?.messages ?? [];
        response = await promptWithRetry(this.tools.ai, {
          ...baseRequest,
          model: { speed: "capable", cost: "high" },
          messages: [
            ...messages,
            ...transcript,
            {
              role: "user",
              content:
                "(system note) You stopped mid-task because you hit the step limit. Using what you have already gathered, give your best final answer now. Only call another tool if it is truly essential.",
            },
          ],
          maxSteps: 8,
        } as any);
      }

      let finalText =
        response.text?.trim() ||
        "I wasn't able to come up with a complete answer. Could you rephrase or narrow the request?";
      if (response.finishReason === "length") {
        finalText += "\n\n*(I hit a length limit — ask me to continue for more.)*";
      }
```

Then use `finalText` where `response.text` was used. Keep the `as any` casts with the TS2589 comment where the compiler complains.

- [ ] **Step 4: Differentiate failure modes in the catch**

Replace the catch block's static message:

```typescript
    } catch (error) {
      // Twists run sandboxed with no PostHog access — console is the only sink.
      console.error("Plot assistant respond failed", error);
      const content = isTransientAiError(error)
        ? "The AI service is briefly overloaded — please try again in a moment."
        : "Sorry, I ran into an issue handling that request. Please try again.";
      await this.tools.plot.createNote({ thread: { id: thread.id }, content });
    }
```

- [ ] **Step 5: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): budget-aware loop — 16 steps, Pro continuation on step exhaustion, transient retry, honest failure modes"
```

---

### Task 8: Progress note + per-thread lock (`twists/plot`)

**Files:**
- Create: `twists/plot/src/progress.ts`
- Modify: `twists/plot/src/index.ts` (`respond()`: progress lifecycle, lock bracket, wire `onProgress`)

**Interfaces:**
- Consumes: `createNote → Promise<Uuid>`, `updateNote({id, content, actions})`, `store.acquireLock/releaseLock` (base tool, no build() change).
- Produces:

```typescript
// progress.ts
export class TurnProgress {
  static async start(plot: Plot, threadId: Uuid, initial?: string): Promise<TurnProgress>;
  update(message: string): Promise<void>; // best-effort; errors swallowed to console
  finish(content: string, actions?: Action[]): Promise<void>; // progress note BECOMES the answer
  readonly noteId: Uuid;
}
```

- `respond()` shape: acquire `respond:{threadId}` lock (TTL 120s, poll 5s up to 45s, proceed anyway on timeout); progress note replaces the separate final `createNote`; error path finishes the progress note with the error message.

- [ ] **Step 1: Implement `progress.ts`**

```typescript
import type { Action, Uuid } from "@plotday/twister";
import type { Plot } from "@plotday/twister/tools/plot";

/**
 * A single note that tracks the assistant's work and finally BECOMES the
 * answer: created at turn start, updated as tools run, replaced by the
 * final content (so the thread never shows a stale "working…" stub).
 */
export class TurnProgress {
  private constructor(
    private readonly plot: Plot,
    private readonly threadId: Uuid,
    readonly noteId: Uuid
  ) {}

  static async start(plot: Plot, threadId: Uuid, initial = "Working on it…"): Promise<TurnProgress> {
    const noteId = await plot.createNote({
      thread: { id: threadId },
      content: `*${initial}*`,
    });
    return new TurnProgress(plot, threadId, noteId);
  }

  async update(message: string): Promise<void> {
    try {
      await this.plot.updateNote({ id: this.noteId, content: `*${message}*` });
    } catch (error) {
      // Progress is cosmetic — never let it break the turn.
      console.error("Progress update failed", error);
    }
  }

  async finish(content: string, actions?: Action[]): Promise<void> {
    await this.plot.updateNote({
      id: this.noteId,
      content,
      actions: actions && actions.length > 0 ? actions : undefined,
    });
  }
}
```

(Check `NoteUpdate`'s field for actions in `public/twister/src/plot.ts` — if partial note updates don't accept `actions`, fall back to: `finish` updates content only, and actions post as today via the final `createNote`; in that case keep the progress note for status and DELETE this class's `finish`-with-actions signature accordingly. Verify before wiring.)

- [ ] **Step 2: Wire progress + lock into `respond()`**

```typescript
  async respond(note: Note): Promise<void> {
    const thread = note.thread;
    const lockKey = `respond:${thread.id}`;
    let locked = await this.tools.store.acquireLock(lockKey, 120_000);
    for (let attempt = 0; !locked && attempt < 9; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 5_000));
      locked = await this.tools.store.acquireLock(lockKey, 120_000);
    }
    // If still locked after ~45s the holder likely crashed mid-TTL; proceed
    // anyway rather than dropping the user's message.
    try {
      await this.respondLocked(note);
    } finally {
      if (locked) await this.tools.store.releaseLock(lockKey);
    }
  }
```

Move the existing body into `private async respondLocked(note: Note)`. Inside it:
- After the AI-availability check and `Tag.Twist` set, create the progress note: `const progress = await TurnProgress.start(this.tools.plot, thread.id as Uuid);`
- `toolCtx.onProgress = (m) => progress.update(m);`
- Replace the final `createNote` with `await progress.finish(finalText, actions.length > 0 ? actions : undefined);`
- Replace the catch-path `createNote` with `await progress.finish(content);` (guard: if `progress` failed to create, fall back to `createNote`).
- The empty-history greeting path returns before progress creation (unchanged).

- [ ] **Step 3: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): live progress note that becomes the answer + per-thread respond lock"
```

---

### Task 9: Context management — history cap + rolling summary (`twists/plot`)

**Files:**
- Modify: `twists/plot/src/messages.ts`, `twists/plot/src/index.ts`
- Test: `twists/plot/src/messages.test.ts` (extend)

**Interfaces:**
- Produces:

```typescript
// messages.ts additions
export const MAX_TURNS = 40;
export const MAX_CHARS_PER_MESSAGE = 8000;
export function partitionHistory(merged: ChatMessage[], maxTurns?: number): {
  older: ChatMessage[];
  recent: ChatMessage[]; // recent[0] is guaranteed role "user"
};
export function withSummary(recent: ChatMessage[], summary: string | null, omittedCount: number): ChatMessage[];
```

- `buildMessages` gains per-message truncation at `MAX_CHARS_PER_MESSAGE` (suffix `…`).
- Store keys: `summary:{threadId}` → `{ coveredTurns: number; text: string }` (SuperJSON-safe object).

- [ ] **Step 1: Extend tests (failing)**

Append to `messages.test.ts`:

```typescript
import { MAX_TURNS, partitionHistory, withSummary } from "./messages";

describe("partitionHistory", () => {
  const mk = (n: number) =>
    Array.from({ length: n }, (_, i) => ({
      role: (i % 2 === 0 ? "user" : "assistant") as const,
      content: `m${i}`,
    }));

  it("keeps everything under the cap", () => {
    const { older, recent } = partitionHistory(mk(10));
    expect(older).toHaveLength(0);
    expect(recent).toHaveLength(10);
  });

  it("splits at the cap and starts recent on a user turn", () => {
    const { older, recent } = partitionHistory(mk(50), 40);
    expect(older.length + recent.length).toBe(50);
    expect(recent.length).toBeLessThanOrEqual(40);
    expect(recent[0].role).toBe("user");
  });
});

describe("withSummary", () => {
  it("prepends a user-role context block and preserves alternation", () => {
    const recent = [{ role: "user" as const, content: "latest" }];
    const out = withSummary(recent, "They discussed X.", 12);
    expect(out[0].role).toBe("user");
    expect(out[0].content).toContain("They discussed X.");
    expect(out[0].content).toContain("latest");
  });
});
```

- [ ] **Step 2: Implement in `messages.ts`**

```typescript
export const MAX_TURNS = 40;
export const MAX_CHARS_PER_MESSAGE = 8000;

export function partitionHistory(
  merged: ChatMessage[],
  maxTurns = MAX_TURNS
): { older: ChatMessage[]; recent: ChatMessage[] } {
  if (merged.length <= maxTurns) return { older: [], recent: merged };
  let cut = merged.length - maxTurns;
  // Recent must start with a user turn (provider requirement).
  while (cut < merged.length && merged[cut].role === "assistant") cut++;
  return { older: merged.slice(0, cut), recent: merged.slice(cut) };
}

export function withSummary(
  recent: ChatMessage[],
  summary: string | null,
  omittedCount: number
): ChatMessage[] {
  if (recent.length === 0) return recent;
  const header = summary
    ? `[Context: ${omittedCount} earlier messages omitted. Summary: ${summary}]`
    : `[Context: ${omittedCount} earlier messages omitted.]`;
  const [first, ...rest] = recent;
  // Merge into the first user turn to preserve role alternation.
  return [{ role: "user", content: `${header}\n\n${first.content}` }, ...rest];
}
```

Also apply `MAX_CHARS_PER_MESSAGE` inside `buildMessages`'s mapping step: `content: truncate(n.content as string)` where `truncate` clips at the cap with a trailing `…` (local helper — do not import from tools.ts to keep the module dependency-free).

- [ ] **Step 3: Wire the rolling summary in `index.ts` (`respondLocked`)**

```typescript
      const merged = buildMessages(previousNotes);
      const { older, recent } = partitionHistory(merged);
      let messages: ChatMessage[] = recent;
      if (older.length > 0) {
        messages = withSummary(recent, await this.threadSummary(thread.id, older), older.length);
      }
```

with:

```typescript
  /**
   * Rolling summary of trimmed-off history, cached per thread. Regenerated
   * only when 10+ new turns have aged out since the cached summary.
   */
  private async threadSummary(threadId: string, older: ChatMessage[]): Promise<string | null> {
    const key = `summary:${threadId}`;
    const cached = await this.get<{ coveredTurns: number; text: string }>(key);
    if (cached && older.length < cached.coveredTurns + 10) return cached.text;
    try {
      const response = await this.tools.ai.prompt({
        model: { speed: "fast", cost: "medium" },
        prompt:
          "Summarize this earlier conversation in under 200 words, keeping named people, projects, decisions, and open questions:\n\n" +
          older.map((m) => `${m.role}: ${m.content}`).join("\n").slice(0, 30_000),
      });
      const text = response.text?.trim();
      if (!text) return cached?.text ?? null;
      await this.set(key, { coveredTurns: older.length, text });
      return text;
    } catch (error) {
      console.error("Thread summary failed", error);
      return cached?.text ?? null; // summary is an enhancement, never a blocker
    }
  }
```

- [ ] **Step 4: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): history cap with rolling cached summary and per-message truncation"
```

---

### Task 10: Background continuation via `runTask` (`twists/plot`)

**Files:**
- Modify: `twists/plot/src/index.ts`

**Interfaces:**
- Consumes: `this.runTask(callback)` (fresh ~1000-request execution), `this.callback(method, ...extraArgs)`, `this.set/get/clear` (SuperJSON — plain objects/arrays only), Tasks 7-8 machinery.
- Produces: `continueInBackground(stateKey: string): Promise<void>` twist method; store key `bg:{noteId}` → `{ threadId, focusId, progressNoteId, messages }` where `messages` is the serializable `ChatMessage[]` + tool-transcript array passed to the continuation prompt.
- Behavior: if the Task-7 continuation ALSO ends `"tool-calls"`, do not shrug — persist state, tell the user work continues, hand off to a fresh execution (exactly one background hop; the background turn must produce a final answer).

- [ ] **Step 1: Hand-off in `respondLocked`**

After the Task-7 continuation block:

```typescript
      if (response.finishReason === "tool-calls") {
        // Two budgets exhausted — hand off to a fresh execution.
        const stateKey = `bg:${note.id}`;
        await this.set(stateKey, {
          threadId: thread.id as string,
          focusId: note.thread.focus.id as string,
          progressNoteId: progress.noteId as string,
          messages: [
            ...messages,
            ...((response.response?.messages ?? []) as unknown[]),
          ] as unknown as Serializable,
        });
        await progress.update("This is taking longer than one pass — I'm still working and will post the answer here.");
        await this.runTask(await this.callback(this.continueInBackground, stateKey));
        handedOff = true; // finally must NOT clear Tag.Twist — the background task owns it now
        return;
      }
```

Declare `let handedOff = false;` at the top of `respondLocked` and change the `finally` to:

```typescript
    } finally {
      if (!handedOff) {
        await this.tools.plot.updateThread({
          id: thread.id,
          twistTags: { [Tag.Twist]: false },
        });
      }
    }
```

- [ ] **Step 2: Implement `continueInBackground`**

```typescript
  /**
   * Fresh-budget continuation for turns that exhausted two prompt rounds.
   * Exactly one hop: this run must end with a final answer.
   */
  async continueInBackground(stateKey: string): Promise<void> {
    const state = await this.get<{
      threadId: string;
      focusId: string;
      progressNoteId: string;
      messages: unknown[];
    }>(stateKey);
    if (!state) return; // already handled or expired

    const threadId = state.threadId as Uuid;
    try {
      const referencedThreadIds = new Set<string>();
      const progressUpdate = async (message: string) => {
        try {
          await this.tools.plot.updateNote({
            id: state.progressNoteId as Uuid,
            content: `*${message}*`,
          });
        } catch (error) {
          console.error("Background progress update failed", error);
        }
      };
      const toolCtx: AgentToolContext = {
        plot: this.tools.plot,
        currentFocusId: state.focusId as Uuid,
        currentThreadId: state.threadId,
        referencedThreadIds,
        onProgress: progressUpdate,
        proposePlan: async () =>
          "Reorganization plans can't be built in a background continuation — ask the user to repeat the reorganize request.",
      };

      const { webSearch: canWebSearch } = await this.tools.ai.available();
      const response = await promptWithRetry(this.tools.ai, {
        model: { speed: "capable", cost: "high" },
        system: SYSTEM_PROMPT,
        messages: [
          ...state.messages,
          {
            role: "user",
            content:
              "(system note) You are in a final continuation with a fresh budget. Finish the task and give your complete final answer now.",
          },
        ],
        tools: buildAgentTools(toolCtx),
        webSearch: canWebSearch,
        maxSteps: 24,
      } as any);

      const finalText =
        response.text?.trim() ||
        "I gathered a lot but couldn't finish cleanly — could you narrow the request?";
      const actions = buildActions(referencedThreadIds, state.threadId, response.sources);
      await this.tools.plot.updateNote({
        id: state.progressNoteId as Uuid,
        content: finalText,
        actions: actions.length > 0 ? actions : undefined,
      });
    } catch (error) {
      console.error("Background continuation failed", error);
      await this.tools.plot.updateNote({
        id: state.progressNoteId as Uuid,
        content: "Sorry — I ran out of room finishing that request. Please try a narrower ask.",
      });
    } finally {
      await this.clear(stateKey);
      await this.tools.plot.updateThread({
        id: threadId,
        twistTags: { [Tag.Twist]: false },
      });
    }
  }
```

(SuperJSON serializes the AI-SDK message objects if they're plain data — verify with a `pnpm lint` type-check and, if `AIMessage` contains non-plain parts, store `JSON.parse(JSON.stringify(messages))`. `Serializable` is exported from `@plotday/twister`.)

- [ ] **Step 3: Test, lint, commit**

```bash
cd twists/plot && pnpm test && pnpm lint
git add twists/plot && git commit -m "feat(plot-twist): one-hop background continuation with fresh budget via runTask"
```

---

### Task 11: Docs, changeset validation, finalize

**Files:**
- Create: `docs/updates.d/<slug>.md` (via `pnpm updates:new`)
- Modify: `docs/features.md` (assistant capabilities section)

- [ ] **Step 1: Updates fragment**

```bash
pnpm updates:new "Plot assistant upgrades"
```

Edit the generated fragment:

```markdown
### Plot assistant

- Approving an organization plan now actually applies the changes, and the assistant reports exactly what succeeded.
- The assistant now searches your whole workspace (every focus), can read any thread it finds, and shows live progress while it works.
- Long or complex requests keep going instead of stopping halfway — the assistant continues in the background and posts the finished answer.

### Fixes

- Rejecting an assistant plan no longer replies "Done!"; new focuses are only created after you approve the plan.
```

- [ ] **Step 2: features.md**

Update the assistant/AI section of `docs/features.md` to describe: workspace-wide semantic search with follow-up thread reading, approval-gated reorganization plans that execute on approval with per-operation results, live progress, and background continuation for long tasks.

- [ ] **Step 3: Run the finalize checklist**

Invoke the `/finalize` skill (mandatory before completion): lint all changed packages (`twists/plot`, `workers/api`, `apps/plot` via `flutter analyze`, `public/twister`), verify backwards compatibility (old queued plan actions: legacy Flutter renders `default:` type names — acceptable; old plan callbacks receive the extra `approved` arg AFTER `action` and BEFORE curried extras — `twists/plot` is the only plan consumer and is updated in lockstep), confirm changeset exists, confirm the `public/` submodule needs its own PR.

- [ ] **Step 4: Full test sweep + commit docs**

```bash
cd twists/plot && pnpm test && cd ../..
cd workers/api && pnpm vitest run src/twist/tools/plot/plan.test.ts && cd ../..
cd apps/plot && flutter test test/store/user_action_plan_test.dart && cd ../..
git add docs && git commit -m "docs: assistant harness upgrade — updates fragment and features"
```

---

## Self-Review Notes

- **Spec coverage:** Bug 1 → Tasks 1/2/6; Bug 2 → Tasks 1/6 (deferred createFocus); Bug 3/4 → Task 5; Rec A → Tasks 2/6; B → Task 5; C → Task 7; D → Task 10; E → Task 8; F → Task 9; G+H → Task 6 (Pro planner w/ conversation) + Task 7 (Pro continuation); I → Task 8; J → Task 7; K → Tasks 4 + tests throughout; Flutter staleness → Task 3.
- **Known judgment calls encoded above:** approval executes server-side with a full-access Plot (user approval = consent, ops were displayed verbatim); rejected plans keep their token (late approval allowed); plan scope stays current-focus (reorg is focus-local); exactly one background hop.
- **Type consistency:** `PlanOperationResult`, `createFocus {focusId,title}`, `(action, approved, threadId)` callback shape, `AgentToolContext`, `ChatMessage` are defined once (Tasks 1/5/4) and consumed by name elsewhere.
