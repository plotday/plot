# GitHub PR Thread Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the GitHub connector's webhook-path field gaps, sync inline PR review comments (a prerequisite that doesn't exist today), and add two-way emoji reaction sync for both comment types.

**Architecture:** All connector work lives in `public/connectors/github/src/`. Reaction sync needs one new platform primitive — `Integrations.setNoteReactions()`, a clear-and-replace reaction write that doesn't exist today (the existing `saveLink`/`saveNotes` reaction path is additive-only and can't express a GitHub-side reaction removal) — added to the twister SDK (`public/twister/src/tools/integrations.ts`) and implemented in the runtime (`workers/api/src/twist/tools/plot/note.ts` + `workers/api/src/twist/tools/integrations.ts`). GitHub has no reaction webhook, so inbound reaction sync is a `scheduleRecurring` poll (every 15 min, open PRs only) that the connector's own KV state (`this.set`/`this.get`) drives, since connectors cannot read back their own previously-synced links/notes from the platform.

**Tech Stack:** TypeScript, `@plotday/twister` connector SDK, Cloudflare Workers (twist runtime), Kysely (Postgres), Vitest.

## Global Constraints

- Never touch the production database. All schema/DB work happens against the local dev DB only (`$DATABASE_URL`, verify with `psql "$DATABASE_URL" -tAc "show port;"` in a worktree).
- Any change to `public/twister/src/` requires a changeset at `public/.changeset/<name>.md` — see root `AGENTS.md` "Changesets" section. Use `minor` (new export/field) with an `Added:` prefix.
- New inline review comments authored from Plot (as opposed to replies) are explicitly out of scope — GitHub requires a file/line/commit position Plot's UI can't supply.
- Status-change-triggers-merge is explicitly out of scope — no changes to `onLinkUpdated`/`updatePRStatus`.
- Follow `public/connectors/AGENTS.md` conventions throughout: `note.key` for upserts, `channelId` set at the top level of every `NewLinkWithNotes`, `initialSync` propagated through every entry point, best-effort/non-throwing write-backs.
- This repo's `/finalize` checklist applies before this work is considered done: lint, backwards compatibility, error capture, docs fragment (`docs/updates.d/`).

---

### Task 1: Add test infrastructure to the GitHub connector

The GitHub connector currently has no tests and no `vitest.config.ts` — every other connector touched in this plan needs one before any test-driven step below can run.

**Files:**
- Create: `public/connectors/github/vitest.config.ts`
- Modify: `public/connectors/github/package.json`

**Interfaces:**
- Produces: `pnpm test` runnable in `public/connectors/github` via `vitest run`.

- [ ] **Step 1: Create the vitest config**

```typescript
// public/connectors/github/vitest.config.ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // Resolve workspace connector packages from their TypeScript source
    // using the @plotday/connector export condition (same as the build path).
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
```

- [ ] **Step 2: Add the test script and vitest devDependency to package.json**

Edit `public/connectors/github/package.json`: in `"scripts"`, add `"test": "vitest run"` alongside the existing `build`/`clean`/`deploy`/`lint` entries. In `"devDependencies"`, add `"vitest": "^2.1.8"` alongside the existing `"typescript": "^5.9.3"` (match the exact version pinned in `public/connectors/google-drive/package.json`).

- [ ] **Step 3: Install and verify**

Run: `cd public/connectors/github && pnpm install`
Then: `pnpm test`
Expected: vitest runs and reports "No test files found" (or exits 0) — confirms the harness is wired before any real test exists.

- [ ] **Step 4: Commit**

```bash
git add public/connectors/github/vitest.config.ts public/connectors/github/package.json public/pnpm-lock.yaml
git commit -m "test: add vitest infrastructure to the github connector"
```

---

### Task 2: Add the `setNoteReactions` SDK type + changeset

Declares the new platform primitive's type contract in the twister SDK. This is a type-only declaration (`abstract` method, no body) — the concrete implementation is Task 3.

**Files:**
- Modify: `public/twister/src/tools/integrations.ts`
- Create: `public/.changeset/github-set-note-reactions.md`

**Interfaces:**
- Produces: `Integrations.setNoteReactions(thread: { id: Uuid } | { source: string }, key: string, reactions: NewReactions): Promise<void>` — an abstract method connectors can call via `this.tools.integrations.setNoteReactions(...)`.
- Consumes: `NewReactions` (already defined in `public/twister/src/plot.ts`, re-exported from the package root `..`).

- [ ] **Step 1: Add `NewReactions` to the file's import list**

In `public/twister/src/tools/integrations.ts`, the top import block currently reads:

```typescript
import {
  type Actor,
  type ActorId,
  type NewContact,
  type NewLinkWithNotes,
  type NewNote,
  type ReactionCapabilities,
  ITool,
} from "..";
```

Change it to:

```typescript
import {
  type Actor,
  type ActorId,
  type NewContact,
  type NewLinkWithNotes,
  type NewNote,
  type NewReactions,
  type ReactionCapabilities,
  ITool,
} from "..";
```

- [ ] **Step 2: Add the abstract method declaration**

Immediately after the existing `saveCustomEmoji` declaration (the last method in the class, ending at line 606 as of this writing), add:

```typescript
  /**
   * Set the COMPLETE current reaction state for an existing note, addressed
   * by its parent thread + key. Unlike {@link saveNotes}/{@link saveNote}
   * (additive/per-emoji-merge — an omitted emoji is left untouched, and
   * actors already reacted are never removed), this CLEARS AND REPLACES:
   * the `reactions` passed here becomes the note's entire reaction state.
   * An emoji that was previously present but is omitted here is removed;
   * an actor previously present for an emoji but absent from its new actor
   * list is removed.
   *
   * Use this when reconciling a note's reactions against an external
   * system's live snapshot — e.g. a connector polling reactions because the
   * external system has no reaction webhook (GitHub) and the poll response
   * is already a full current state, including removals.
   *
   * Never creates a note — throws if no note with `key` exists on the
   * resolved thread among this connector's own links.
   *
   * @param thread - `{ id }` or `{ source }` identifying the note's thread
   * @param key - the existing note's `key`
   * @param reactions - the note's complete reaction state to converge to
   */
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  abstract setNoteReactions(
    thread: { id: Uuid } | { source: string },
    key: string,
    reactions: NewReactions
  ): Promise<void>;
}
```

Note the trailing `}` — this closes the `Integrations` class, so make sure you're replacing the file's final `}` rather than duplicating it. Verify by reading the file's last 10 lines after editing.

- [ ] **Step 3: Add the changeset**

```markdown
---
"@plotday/twister": minor
---

Added: `Integrations.setNoteReactions()` for connectors to reconcile a note's complete reaction state against an external system, replacing (not merging with) any existing reactions.
```

Save as `public/.changeset/github-set-note-reactions.md`.

- [ ] **Step 4: Validate the changeset**

Run: `cd public && pnpm validate-changesets`
Expected: passes with no errors.

- [ ] **Step 5: Build twister and verify the type surface**

Run: `cd public/twister && pnpm build`
Expected: builds with no TypeScript errors.

- [ ] **Step 6: Commit**

```bash
cd public
git add twister/src/tools/integrations.ts .changeset/github-set-note-reactions.md
git commit -m "feat(twister): add Integrations.setNoteReactions for reaction reconciliation"
```

(This commit is in the `public/` submodule — per root `AGENTS.md`, submodule changes land in their own PR against the public repo. Don't push yet; later tasks add more submodule commits on the same branch.)

---

### Task 3: Implement `setNoteReactions` in the runtime

Wires the new abstract method to a concrete implementation: a new `setNoteReactionsForConnector` function in `note.ts` (mirrors `updateNote`'s clear-and-replace reaction block, but resolves notes the way `createNote`/`saveNotes` do for connector callers — via `{id}`/`{source}` thread lookup and a `link.created_by`-scoped key lookup, not a per-user `Plot`-tool key lookup), plus a thin `Integrations.setNoteReactions` wrapper that calls it via the existing `this.getPlot()` internal-context helper.

**Files:**
- Modify: `workers/api/src/twist/tools/plot/note.ts`
- Modify: `workers/api/src/twist/tools/integrations.ts`
- Create: `workers/api/src/twist/tools/integrations-set-note-reactions.test.ts`

**Interfaces:**
- Consumes: `Plot` class (`plot.db`, `plot.getUserId()`, `plot.getPriorityRoot()`, `plot.getUpdatedBy()`, `plot.syncDepth`, `plot.twistInstanceId`, `plot.notifySyncDOs()`, `processNewActorArray` — all already used elsewhere in `note.ts`), `Integrations.getPlot()` (already used by `saveNotes`, `integrations.ts:1715`).
- Produces: `setNoteReactionsForConnector(plot: Plot, thread: { id: string } | { source: string }, key: string, reactions: NewReactions): Promise<void>` (exported from `note.ts`); `Integrations.setNoteReactions(thread, key, reactions): Promise<void>` (method on the runtime `Integrations` class, fulfilling the Task 2 abstract signature).

- [ ] **Step 1: Add `NewReactions` to `note.ts`'s import from `@plotday/twister/plot`**

In `workers/api/src/twist/tools/plot/note.ts`, find the import block starting `import { ..., type NewNote, ... } from "@plotday/twister/plot";` (around line 8-14) and add `type NewReactions` to it:

```typescript
  type NewNote,
  type NewReactions,
```

- [ ] **Step 2: Write `setNoteReactionsForConnector`**

Add this function to `workers/api/src/twist/tools/plot/note.ts`, immediately after the `updateNote` function (which ends at line 1483 as of this writing — verify by reading the file before inserting):

```typescript
/**
 * Set the complete reaction state for an existing note, for connector
 * callers (via `Integrations.setNoteReactions`). Mirrors `updateNote`'s
 * clear-and-replace reaction semantics, but resolves the target note the
 * way connector-facing functions do: `{id}`/`{source}` thread lookup (like
 * `createNote`'s no-note-link branch) and a key lookup scoped to this
 * connector's own links on the thread (like `updateNote`'s key lookup),
 * never through a per-user `thread_priority` key scope.
 *
 * Never creates a note or a thread — throws if the thread or the keyed
 * note doesn't already exist.
 */
export async function setNoteReactionsForConnector(
  plot: Plot,
  thread: { id: string } | { source: string },
  key: string,
  reactions: NewReactions
): Promise<void> {
  try {
    // Resolve thread id.
    let activityId: string;
    if ("id" in thread) {
      activityId = thread.id;
    } else {
      const priorityRoot = await plot.getPriorityRoot();
      const existingLink = await plot.db
        .selectFrom("link")
        .select("thread_id")
        .where("source_priority_root", "=", priorityRoot)
        .where(
          sql<boolean>`(link.source = ${thread.source} OR link.sources @> ARRAY[${thread.source}]::text[])`
        )
        .executeTakeFirst();

      if (!existingLink || !existingLink.thread_id) {
        throw new Error(
          `Activity not found with source "${thread.source}": Not found`
        );
      }
      activityId = existingLink.thread_id;
    }

    // Resolve the note by key, scoped to this connector's own links on the
    // thread so we never touch another connector's same-keyed note after a
    // thread merge (mirrors updateNote's key-lookup scoping).
    const twistInstanceId = plot.twistInstanceId;
    const existingNote = await plot.db
      .selectFrom("note")
      .select(["note.id"])
      .where("note.thread_id", "=", activityId)
      .where("note.key", "=", key)
      .$if(twistInstanceId != null, (qb) =>
        qb
          .innerJoin("link", "link.id", "note.link_id")
          .where("link.created_by", "=", twistInstanceId!)
      )
      .executeTakeFirst();

    if (!existingNote) {
      throw new Error(`Note not found with key "${key}": Not found`);
    }
    const noteId = existingNote.id;

    // Resolve priorityId for the sync-DO nudge below (connector calls act
    // as the twist instance owner, mirroring createNote's no-context branch).
    const userId = await plot.getUserId();
    const tp = await plot.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", activityId)
      .where("user_id", "=", userId)
      .executeTakeFirst();
    const priorityId = tp?.priority_id;

    // Clear and replace — identical shape to updateNote's reaction block.
    await plot.db
      .deleteFrom("note_reaction")
      .where("note_id", "=", noteId)
      .execute();

    const reactionInserts: Array<{
      note_id: string;
      emoji: string;
      actor_id: string;
      updated_by: number;
      sync_depth: number;
    }> = [];
    for (const [emoji, newActors] of Object.entries(reactions)) {
      if (!newActors || newActors.length === 0) continue;
      const actorIds = await processNewActorArray(
        plot,
        newActors,
        priorityId ?? ""
      );
      for (const actorId of actorIds) {
        reactionInserts.push({
          note_id: noteId,
          emoji,
          actor_id: actorId,
          updated_by: plot.getUpdatedBy(),
          sync_depth: plot.syncDepth + 1,
        });
      }
    }
    if (reactionInserts.length > 0) {
      await plot.db
        .insertInto("note_reaction")
        .values(reactionInserts)
        .execute();
    }

    if (priorityId) {
      await plot.notifySyncDOs(new Set([priorityId]));
    }
  } catch (error) {
    throw await handleDbOperationError(error, "setNoteReactions", plot, {
      has_thread_id: "id" in thread,
      key,
    });
  }
}
```

- [ ] **Step 3: Wire the `Integrations.setNoteReactions` method**

In `workers/api/src/twist/tools/integrations.ts`, add `setNoteReactionsForConnector` to the import from `./plot/note` (find the existing import of note.ts functions — it already imports several, e.g. wherever `createNotes`-adjacent functions are pulled in; add `setNoteReactionsForConnector` alongside them), and add `type NewReactions` to the existing `@plotday/twister/plot`-style type imports at the top of the file (mirroring Step 1 of this task).

Add the method immediately after `saveNotes` (which ends around line 1732 as of this writing — verify by reading before inserting):

```typescript
  /**
   * Set the complete reaction state for an existing note. See
   * {@link setNoteReactionsForConnector} for exact clear-and-replace
   * semantics — this is a thin wrapper that resolves this tool's `Plot`
   * context and delegates.
   */
  async setNoteReactions(
    thread: { id: Uuid } | { source: string },
    key: string,
    reactions: NewReactions
  ): Promise<void> {
    const plot = this.getPlot();
    await setNoteReactionsForConnector(plot, thread, key, reactions);
  }
```

- [ ] **Step 4: Write the DB-backed test**

Follow the pattern established in `integrations-connection-drift.test.ts` (transaction + rollback, real schema). Create `workers/api/src/twist/tools/integrations-set-note-reactions.test.ts`:

```typescript
import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../../db";
import type { Bindings } from "../../env";
import { setNoteReactionsForConnector } from "./plot/note";
import { Plot } from "./plot";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

describe.skipIf(!DATABASE_URL)("setNoteReactionsForConnector", () => {
  it("clears and replaces a note's reaction state, including removals", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const userId = randomUUID();
    const twistInstanceId = randomUUID();
    const threadId = randomUUID();
    const linkId = randomUUID();
    const noteId = randomUUID();
    const actorA = randomUUID();
    const actorB = randomUUID();

    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email)
          VALUES (${userId}::uuid, ${`reactions-${userId}@example.test`})`.execute(trx);
        await sql`INSERT INTO twist
            (twist_package_id, user_id, environment, name, handle, version,
             is_source, shared)
          VALUES (${randomUUID()}::uuid, ${userId}::uuid, 'personal',
            'GitHub', 'github', '1.0.0', true, false)`.execute(trx);
        const twistRow = await sql<{ id: string }>`
          SELECT id::text FROM twist WHERE user_id = ${userId}::uuid`.execute(trx);
        const twistId = twistRow.rows[0]!.id;
        await sql`INSERT INTO twist_instance (id, twist_id, owner_id, name, draft)
          VALUES (${twistInstanceId}::uuid, ${twistId}::bigint, ${userId}::uuid,
            'GitHub', false)`.execute(trx);
        await sql`INSERT INTO contact (id, user_id, "primary", email)
          VALUES (${userId}::uuid, ${userId}::uuid, true, ${`reactions-${userId}@example.test`})`.execute(trx);
        await sql`INSERT INTO priority (id, user_id, path, title)
          VALUES (${randomUUID()}::uuid, ${userId}::uuid, 'root', 'Root')`.execute(trx);
        const priorityRow = await sql<{ id: string }>`
          SELECT id::text FROM priority WHERE user_id = ${userId}::uuid LIMIT 1`.execute(trx);
        const priorityId = priorityRow.rows[0]!.id;
        await sql`INSERT INTO thread (id, title, created_by, draft, contacts)
          VALUES (${threadId}::uuid, 'Test PR', ${twistInstanceId}::uuid, false,
            ARRAY[${userId}::uuid])`.execute(trx);
        await sql`INSERT INTO thread_priority (thread_id, user_id, priority_id)
          VALUES (${threadId}::uuid, ${userId}::uuid, ${priorityId}::uuid)`.execute(trx);
        await sql`INSERT INTO link (id, thread_id, created_by, source, type, channel_id)
          VALUES (${linkId}::uuid, ${threadId}::uuid, ${twistInstanceId}::uuid,
            'github:pr:test/repo/1', 'pull_request', 'test/repo')`.execute(trx);
        await sql`INSERT INTO note (id, thread_id, link_id, key, content, author_id, created_by)
          VALUES (${noteId}::uuid, ${threadId}::uuid, ${linkId}::uuid, 'comment-1',
            'Original content', ${userId}::uuid, ${userId}::uuid)`.execute(trx);
        // Seed a pre-existing reaction that the reconciliation below must remove.
        await sql`INSERT INTO note_reaction (note_id, emoji, actor_id, updated_by, sync_depth)
          VALUES (${noteId}::uuid, '🎉', ${actorA}::uuid, 0, 0)`.execute(trx);
        await sql`SET LOCAL session_replication_role = DEFAULT`.execute(trx);

        const plot = new Plot(trx, twistInstanceId, userId);

        // Reconcile to a DIFFERENT reaction state: 🎉/actorA is gone (removal),
        // 👍/actorB is new (addition).
        await setNoteReactionsForConnector(
          plot,
          { id: threadId },
          "comment-1",
          { "👍": [{ id: actorB } as any] }
        );

        const rows = await sql<{ emoji: string; actor_id: string }>`
          SELECT emoji, actor_id::text FROM note_reaction WHERE note_id = ${noteId}::uuid`.execute(trx);
        expect(rows.rows).toEqual([{ emoji: "👍", actor_id: actorB }]);

        // Content untouched — this call must not have gone through the
        // additive saveLink/createNote path.
        const noteRow = await sql<{ content: string }>`
          SELECT content FROM note WHERE id = ${noteId}::uuid`.execute(trx);
        expect(noteRow.rows[0]!.content).toBe("Original content");

        throw new Rollback();
      });
    } catch (e) {
      if (!(e instanceof Rollback)) throw e;
    } finally {
      await db.destroy();
    }
  });
});
```

Note: check the exact `Plot` class constructor signature (`new Plot(trx, twistInstanceId, userId)` above is illustrative — read `workers/api/src/twist/tools/plot.ts`'s actual constructor before writing this step, and adjust the instantiation to match; also confirm whether `NewActor` accepts a bare `{ id: ActorId }` shape as processed by `processNewActorArray`, adjusting the `{ id: actorB } as any` cast if a cleaner typed form exists).

- [ ] **Step 5: Run the test**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/twist/tools/integrations-set-note-reactions.test.ts`
Expected: PASS (or `skip` if `$DATABASE_URL` isn't set — set it per the worktree DB setup in root `AGENTS.md` "Worktree Development" before treating a skip as a pass).

- [ ] **Step 6: Lint and commit**

Run: `pnpm --filter @plotday/api run lint`
Expected: 0 errors.

```bash
git add workers/api/src/twist/tools/plot/note.ts workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations-set-note-reactions.test.ts
git commit -m "feat(api): implement Integrations.setNoteReactions"
```

---

### Task 4: Webhook-path field parity fix

Extracts the description-note + `sourceUrl` + "Open in GitHub" action population (currently only in `convertPRToThread`) into a shared helper, and calls it from the three incremental webhook handlers so a PR whose first sync happens via webhook gets the same fields immediately.

**Files:**
- Modify: `public/connectors/github/src/pr-sync.ts`
- Create: `public/connectors/github/src/pr-sync.test.ts`

**Interfaces:**
- Produces: `buildPRThreadFields(pr: GitHubPullRequest): { actions: Action[]; sourceUrl: string; descriptionNote: any }` — a pure helper other tasks/tests can call directly.

- [ ] **Step 1: Write the failing test**

Create `public/connectors/github/src/pr-sync.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { buildPRThreadFields } from "./pr-sync";
import type { GitHubPullRequest } from "./github";

function makePR(overrides: Partial<GitHubPullRequest> = {}): GitHubPullRequest {
  return {
    id: 1,
    number: 42,
    title: "Add feature",
    body: "This does the thing.",
    state: "open",
    html_url: "https://github.com/acme/repo/pull/42",
    created_at: "2026-07-01T00:00:00Z",
    updated_at: "2026-07-01T00:00:00Z",
    closed_at: null,
    merged_at: null,
    user: { id: 1, login: "octocat" },
    assignee: null,
    draft: false,
    base: { repo: { full_name: "acme/repo", owner: { login: "acme" }, name: "repo" } },
    ...overrides,
  };
}

describe("buildPRThreadFields", () => {
  it("sets sourceUrl to the PR's html_url", () => {
    const fields = buildPRThreadFields(makePR());
    expect(fields.sourceUrl).toBe("https://github.com/acme/repo/pull/42");
  });

  it("includes an Open in GitHub action pointing at html_url", () => {
    const fields = buildPRThreadFields(makePR());
    expect(fields.actions).toEqual([
      { type: "external", title: "Open in GitHub", url: "https://github.com/acme/repo/pull/42" },
    ]);
  });

  it("builds a description note with the PR body", () => {
    const fields = buildPRThreadFields(makePR({ body: "Fixes the bug." }));
    expect(fields.descriptionNote.key).toBe("description");
    expect(fields.descriptionNote.content).toBe("Fixes the bug.");
  });

  it("sets description content to null for an empty/whitespace body", () => {
    const fields = buildPRThreadFields(makePR({ body: "   " }));
    expect(fields.descriptionNote.content).toBeNull();
  });

  it("sets description content to null for a null body", () => {
    const fields = buildPRThreadFields(makePR({ body: null }));
    expect(fields.descriptionNote.content).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `buildPRThreadFields` is not exported from `./pr-sync`.

- [ ] **Step 3: Implement `buildPRThreadFields` and use it in `convertPRToThread`**

In `public/connectors/github/src/pr-sync.ts`, add this exported function above `convertPRToThread`:

```typescript
/**
 * Fields common to a PR thread's "identity" — the source URL, the "Open in
 * GitHub" action, and the description note — shared by both the batch-sync
 * path (`convertPRToThread`) and the incremental webhook handlers so a PR
 * whose first sync happens via webhook gets full parity immediately instead
 * of waiting on a later batch resync to backfill it.
 */
export function buildPRThreadFields(pr: GitHubPullRequest): {
  actions: Action[];
  sourceUrl: string;
  descriptionNote: { key: string; content: string | null; created: Date; author: NewContact };
} {
  const hasDescription = Boolean(pr.body && pr.body.trim().length > 0);
  return {
    actions: [
      {
        type: ActionType.external,
        title: `Open in GitHub`,
        url: pr.html_url,
      },
    ],
    sourceUrl: pr.html_url,
    descriptionNote: {
      key: "description",
      content: hasDescription ? pr.body : null,
      created: new Date(pr.created_at),
      author: undefined as unknown as NewContact, // caller fills in author (needs GitHubUser, not just the PR)
    },
  };
}
```

Wait — `descriptionNote.author` needs `source.userToContact(pr.user)`, which requires the `GitHub` instance, not just the PR. Revise the signature to accept it:

```typescript
export function buildPRThreadFields(
  source: GitHub,
  pr: GitHubPullRequest
): {
  actions: Action[];
  sourceUrl: string;
  descriptionNote: { key: string; content: string | null; created: Date; author: NewContact };
} {
  const hasDescription = Boolean(pr.body && pr.body.trim().length > 0);
  return {
    actions: [
      {
        type: ActionType.external,
        title: `Open in GitHub`,
        url: pr.html_url,
      },
    ],
    sourceUrl: pr.html_url,
    descriptionNote: {
      key: "description",
      content: hasDescription ? pr.body : null,
      created: new Date(pr.created_at),
      author: source.userToContact(pr.user),
    },
  };
}
```

Add `import type { NewContact } from "@plotday/twister/plot";` to `pr-sync.ts`'s imports if not already present (check the existing import block first — `github.ts` already imports it this way).

Update the test from Step 1: `buildPRThreadFields` now takes `(source, pr)`. Adjust the test file to construct a minimal fake `source` — the only method it calls is `userToContact`, so:

```typescript
const fakeSource = {
  userToContact: (user: { id: number; login: string }) => ({
    email: `${user.id}+${user.login}@users.noreply.github.com`,
    name: user.login,
    source: { accountId: String(user.id) },
  }),
} as any;
```

and pass `fakeSource` as the first argument in every `buildPRThreadFields(...)` call in the test file. Update the `descriptionNote.author` assertions if you add any (the existing test steps above only assert `content`/`key`, so no further test changes needed beyond the call signature).

Now update `convertPRToThread` to use it — replace the existing inline `threadActions` construction (lines 149-155) and the `notes.push({ key: "description", ... })` block (lines 159-165) with:

```typescript
  const { actions: threadActions, sourceUrl, descriptionNote } = buildPRThreadFields(source, pr);
  const notes: any[] = [descriptionNote];
```

and remove the now-redundant `sourceUrl: pr.html_url` line further down in the returned `thread` object's literal (line 241) — replace it with `sourceUrl,` (reusing the destructured value) to keep a single source of truth.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS (5 tests).

- [ ] **Step 5: Use the helper in the three webhook handlers**

In `handlePRWebhook` (`pr-sync.ts`), after computing `authorContact`/`assigneeContact`, add:

```typescript
  const { actions, sourceUrl, descriptionNote } = buildPRThreadFields(source, pr);
```

and update the returned `thread` object: add `actions,` and `sourceUrl,` to the object literal, and change `notes: []` to `notes: [descriptionNote]` — but only when the action indicates this is a create/edit, not every PR webhook action (e.g. a `synchronize` action, fired on every push to the PR branch, shouldn't re-touch the description). Guard it:

```typescript
  const action = payload.action as string | undefined;
  const notes = action === "opened" || action === "edited" ? [descriptionNote] : [];
```

Use `notes` (not `[descriptionNote]` directly) in the returned thread object.

In `handleReviewWebhock` and `handlePRCommentWebhook`, these don't have the full PR body needed for a description note (the payload's `pull_request`/`issue` field on these events doesn't reliably carry `body` for the *PR* — only for the review/comment itself), so only add `actions`/`sourceUrl`, not the description note. For `handleReviewWebhock`, add after resolving `pr`:

```typescript
  const { actions, sourceUrl } = buildPRThreadFields(source, pr);
```

and add `actions,` / `sourceUrl,` to its returned thread object literal.

For `handlePRCommentWebhook`, the payload only has `issue` (not a full `GitHubPullRequest` — no `html_url` on the PR itself in this event's payload beyond `issue.html_url`, no `id`/`merged_at`/etc.), so `buildPRThreadFields` doesn't apply directly. Instead, set `sourceUrl: issue.html_url` directly (no action button — issue-comment webhooks don't carry enough PR shape to safely reuse the full helper) by adding `sourceUrl: issue.html_url,` to its returned thread object literal.

- [ ] **Step 6: Add regression tests for the webhook-path parity**

Add to `pr-sync.test.ts`:

```typescript
import { handlePRWebhook, handleReviewWebhook, handlePRCommentWebhook } from "./pr-sync";

describe("handlePRWebhook field parity", () => {
  it("sets sourceUrl and actions on an opened PR from a webhook-only sync", async () => {
    const savedLinks: any[] = [];
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
    } as any;

    await handlePRWebhook(
      fakeSource,
      { action: "opened", pull_request: makePR() },
      "acme/repo"
    );

    expect(savedLinks).toHaveLength(1);
    expect(savedLinks[0].sourceUrl).toBe("https://github.com/acme/repo/pull/42");
    expect(savedLinks[0].actions).toEqual([
      { type: "external", title: "Open in GitHub", url: "https://github.com/acme/repo/pull/42" },
    ]);
    expect(savedLinks[0].notes).toEqual([
      expect.objectContaining({ key: "description", content: "This does the thing." }),
    ]);
  });

  it("omits the description note on a synchronize action", async () => {
    const savedLinks: any[] = [];
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
    } as any;

    await handlePRWebhook(
      fakeSource,
      { action: "synchronize", pull_request: makePR() },
      "acme/repo"
    );

    expect(savedLinks[0].notes).toEqual([]);
    expect(savedLinks[0].sourceUrl).toBe("https://github.com/acme/repo/pull/42");
  });
});
```

Move the `makePR` helper from earlier in the file to module scope (top of `pr-sync.test.ts`, outside any `describe` block) so both test groups can use it.

- [ ] **Step 7: Run all tests, then typecheck**

Run: `cd public/connectors/github && pnpm test`
Expected: all PASS.
Run: `pnpm exec tsc --noEmit`
Expected: 0 errors.

- [ ] **Step 8: Commit**

```bash
git add public/connectors/github/src/pr-sync.ts public/connectors/github/src/pr-sync.test.ts
git commit -m "fix(github): backfill sourceUrl/actions/description note on webhook-only sync"
```

---

### Task 5: GitHub emoji mapping module

**Files:**
- Create: `public/connectors/github/src/github-emoji.ts`
- Create: `public/connectors/github/src/github-emoji.test.ts`

**Interfaces:**
- Produces: `GITHUB_REACTION_TO_EMOJI: Record<string, string>`, `EMOJI_TO_GITHUB_REACTION: Record<string, string>`, `ALLOWED_REACTION_EMOJI: readonly string[]` — consumed by Task 6 (`reactionCapabilities`, `onNoteReactionChanged`) and Task 9 (reaction poll).

- [ ] **Step 1: Write the failing test**

Create `public/connectors/github/src/github-emoji.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import {
  ALLOWED_REACTION_EMOJI,
  EMOJI_TO_GITHUB_REACTION,
  GITHUB_REACTION_TO_EMOJI,
} from "./github-emoji";

describe("GITHUB_REACTION_TO_EMOJI", () => {
  it("maps every GitHub reaction content type to its emoji", () => {
    expect(GITHUB_REACTION_TO_EMOJI["+1"]).toBe("👍");
    expect(GITHUB_REACTION_TO_EMOJI["-1"]).toBe("👎");
    expect(GITHUB_REACTION_TO_EMOJI.laugh).toBe("😄");
    expect(GITHUB_REACTION_TO_EMOJI.hooray).toBe("🎉");
    expect(GITHUB_REACTION_TO_EMOJI.confused).toBe("😕");
    expect(GITHUB_REACTION_TO_EMOJI.heart).toBe("❤️");
    expect(GITHUB_REACTION_TO_EMOJI.rocket).toBe("🚀");
    expect(GITHUB_REACTION_TO_EMOJI.eyes).toBe("👀");
  });
});

describe("EMOJI_TO_GITHUB_REACTION", () => {
  it("round-trips every entry in GITHUB_REACTION_TO_EMOJI", () => {
    for (const [content, emoji] of Object.entries(GITHUB_REACTION_TO_EMOJI)) {
      expect(EMOJI_TO_GITHUB_REACTION[emoji]).toBe(content);
    }
  });

  it("returns undefined for an emoji GitHub doesn't support", () => {
    expect(EMOJI_TO_GITHUB_REACTION["🦄"]).toBeUndefined();
  });
});

describe("ALLOWED_REACTION_EMOJI", () => {
  it("lists exactly the 8 GitHub reaction emoji", () => {
    expect(ALLOWED_REACTION_EMOJI).toHaveLength(8);
    expect(new Set(ALLOWED_REACTION_EMOJI)).toEqual(
      new Set(Object.values(GITHUB_REACTION_TO_EMOJI))
    );
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `./github-emoji` module doesn't exist.

- [ ] **Step 3: Implement the mapping module**

Create `public/connectors/github/src/github-emoji.ts`:

```typescript
/**
 * GitHub's reaction "content" values (the fixed enum accepted by
 * `POST /reactions` endpoints) mapped to their Unicode emoji, and back.
 * GitHub's reaction set is fixed — no custom emoji, no open Unicode — so
 * this is the connector's `reactionCapabilities` allow-list too.
 */
export const GITHUB_REACTION_TO_EMOJI: Record<string, string> = {
  "+1": "👍",
  "-1": "👎",
  laugh: "😄",
  hooray: "🎉",
  confused: "😕",
  heart: "❤️",
  rocket: "🚀",
  eyes: "👀",
};

export const EMOJI_TO_GITHUB_REACTION: Record<string, string> = Object.fromEntries(
  Object.entries(GITHUB_REACTION_TO_EMOJI).map(([content, emoji]) => [emoji, content])
);

export const ALLOWED_REACTION_EMOJI: readonly string[] = Object.freeze(
  Object.values(GITHUB_REACTION_TO_EMOJI)
);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS (4 tests, 12 total with Task 4's).

- [ ] **Step 5: Commit**

```bash
git add public/connectors/github/src/github-emoji.ts public/connectors/github/src/github-emoji.test.ts
git commit -m "feat(github): add GitHub reaction <-> emoji mapping"
```

---

### Task 6: `reactionCapabilities` + outbound reaction write-back

**Files:**
- Modify: `public/connectors/github/src/github.ts`
- Create: `public/connectors/github/src/reactions.ts`
- Create: `public/connectors/github/src/reactions.test.ts`

**Interfaces:**
- Consumes: `GITHUB_REACTION_TO_EMOJI`, `EMOJI_TO_GITHUB_REACTION` (Task 5).
- Produces: `commentEndpointForKey(owner: string, repo: string, key: string): { commentId: string; kind: "issue" | "review" } | null` — a pure key-prefix router, reused by Task 9's poller and Task 8's write-back routing. `reactToComment(source: GitHub, owner: string, repo: string, key: string, githubReaction: string): Promise<void>` and `unreactToComment(...)` — the outbound POST/DELETE calls.

- [ ] **Step 1: Write the failing test for the key-prefix router**

Create `public/connectors/github/src/reactions.test.ts`:

```typescript
import { describe, expect, it } from "vitest";
import { commentEndpointForKey } from "./reactions";

describe("commentEndpointForKey", () => {
  it("routes a comment- key to the issue-comment endpoint", () => {
    expect(commentEndpointForKey("comment-123")).toEqual({
      commentId: "123",
      kind: "issue",
    });
  });

  it("routes a review-comment- key to the review-comment endpoint", () => {
    expect(commentEndpointForKey("review-comment-456")).toEqual({
      commentId: "456",
      kind: "review",
    });
  });

  it("returns null for a description key", () => {
    expect(commentEndpointForKey("description")).toBeNull();
  });

  it("returns null for a review- (summary) key", () => {
    expect(commentEndpointForKey("review-789")).toBeNull();
  });

  it("returns null for a null key", () => {
    expect(commentEndpointForKey(null)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `./reactions` module doesn't exist.

- [ ] **Step 3: Implement `commentEndpointForKey` and the outbound reaction calls**

Create `public/connectors/github/src/reactions.ts`:

```typescript
import type { GitHub } from "./github";
import { EMOJI_TO_GITHUB_REACTION } from "./github-emoji";

/**
 * Routes a note `key` to the GitHub API namespace it belongs to.
 * `review-comment-` MUST be checked before `comment-` would ever be
 * confused with it — they're disjoint prefixes, not a shared one, so order
 * doesn't actually matter here, but keep review-comment first for
 * readability since it's the more specific case conceptually.
 */
export function commentEndpointForKey(
  key: string | null
): { commentId: string; kind: "issue" | "review" } | null {
  if (!key) return null;
  const reviewMatch = key.match(/^review-comment-(\d+)$/);
  if (reviewMatch) return { commentId: reviewMatch[1], kind: "review" };
  const issueMatch = key.match(/^comment-(\d+)$/);
  if (issueMatch) return { commentId: issueMatch[1], kind: "issue" };
  return null;
}

function reactionsPath(
  owner: string,
  repo: string,
  commentId: string,
  kind: "issue" | "review"
): string {
  const namespace = kind === "issue" ? "issues" : "pulls";
  return `/repos/${owner}/${repo}/${namespace}/comments/${commentId}/reactions`;
}

/**
 * Add a reaction to a comment. Best-effort: swallows failures (rate limit,
 * comment deleted since) rather than throwing, matching this connector's
 * other write-back calls (`updatePRStatus`).
 */
export async function reactToComment(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  key: string,
  emoji: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  const githubReaction = EMOJI_TO_GITHUB_REACTION[emoji];
  if (!endpoint || !githubReaction) return;

  try {
    const response = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: githubReaction }),
      }
    );
    if (!response.ok) {
      console.warn(
        `[github] Failed to add reaction ${githubReaction} to ${key}: ${response.status}`
      );
    }
  } catch (error) {
    console.warn(`[github] Error adding reaction ${githubReaction} to ${key}:`, error);
  }
}

/**
 * Remove a reaction from a comment. GitHub's DELETE endpoint is keyed on
 * the reaction's OWN id (not the comment id + content), so this must first
 * list the comment's reactions to find which one to delete — the reaction
 * poll (Task 9) already does this same list call, but outbound removal is
 * a separate, immediate user action and can't wait for the next poll.
 */
export async function unreactToComment(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  key: string,
  emoji: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  const githubReaction = EMOJI_TO_GITHUB_REACTION[emoji];
  if (!endpoint || !githubReaction) return;

  try {
    const listResponse = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind) +
        `?content=${encodeURIComponent(githubReaction)}`
    );
    if (!listResponse.ok) return;
    const reactions: Array<{ id: number; user: { login: string } }> =
      await listResponse.json();
    // Best-effort: GitHub's API has no per-user identity we can correlate
    // to "the Plot actor who unreacted" without a second lookup, so this
    // removes the FIRST matching reaction of this content type. In
    // practice each Plot actor maps to exactly one GitHub account, and
    // GitHub only allows one reaction per (user, content) per comment, so
    // this is precise for the common case of that account's own reaction.
    const target = reactions[0];
    if (!target) return;

    const deleteResponse = await source.githubFetch(
      token,
      `${reactionsPath(owner, repo, endpoint.commentId, endpoint.kind)}/${target.id}`,
      { method: "DELETE" }
    );
    if (!deleteResponse.ok) {
      console.warn(
        `[github] Failed to remove reaction ${githubReaction} from ${key}: ${deleteResponse.status}`
      );
    }
  } catch (error) {
    console.warn(`[github] Error removing reaction ${githubReaction} from ${key}:`, error);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS.

- [ ] **Step 5: Declare `reactionCapabilities` and implement `onNoteReactionChanged` in `github.ts`**

In `public/connectors/github/src/github.ts`, add the import:

```typescript
import { reactToComment, unreactToComment } from "./reactions";
import { ALLOWED_REACTION_EMOJI } from "./github-emoji";
```

Add the capability declaration as a class property, near the other `readonly` declarations (after `readonly linkTypes = [...]`):

```typescript
  readonly reactionCapabilities = {
    mode: "fixed" as const,
    allowed: ALLOWED_REACTION_EMOJI,
  };
```

Add the write-back method in the "Write-back hooks" section, after `onNoteUpdated`:

```typescript
  /**
   * Push a single emoji add/remove to GitHub. Dispatched on the reacting
   * user's own GitHub connector instance, so `getToken` resolves to their
   * token and the reaction is attributed to their GitHub account.
   */
  async onNoteReactionChanged(
    note: Note,
    thread: Thread,
    _actor: unknown,
    emoji: string,
    added: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const owner = meta.owner as string | undefined;
    const repo = meta.repo as string | undefined;
    if (!owner || !repo || !note.key) return;

    const syncableId = `${owner}/${repo}`;
    let token: string;
    try {
      token = await this.getToken(syncableId);
    } catch {
      return; // no connection for this user — stays Plot-only, per SDK contract
    }

    if (added) {
      await reactToComment(this, token, owner, repo, note.key, emoji);
    } else {
      await unreactToComment(this, token, owner, repo, note.key, emoji);
    }
  }
```

Check the exact `Actor`/`Note`/`Thread` type imports already present at the top of `github.ts` — `Note` and `Thread` are already imported (used by `onNoteCreated`); add `type Actor` to the same `@plotday/twister` import if not already present, and use `Actor` instead of `unknown` for the `_actor` parameter to match the base class signature exactly (the base declares `actor: Actor`).

- [ ] **Step 6: Typecheck**

Run: `cd public/connectors/github && pnpm exec tsc --noEmit`
Expected: 0 errors. This is the step most likely to catch a signature mismatch against the base `Connector.onNoteReactionChanged` — fix any parameter type mismatch by matching `public/twister/src/connector.ts`'s declared signature exactly.

- [ ] **Step 7: Commit**

```bash
git add public/connectors/github/src/github.ts public/connectors/github/src/reactions.ts public/connectors/github/src/reactions.test.ts
git commit -m "feat(github): declare reaction capabilities and outbound reaction write-back"
```

---

### Task 7: Inline review-comment sync — inbound

Syncs GitHub's inline (code-line) PR review comments into Plot as notes, both via the initial batch sync and a new webhook event, and maintains the connector's own open-PR comment-key state (needed by Task 9's poller, since connectors can't read back their own synced data from the platform).

**Files:**
- Modify: `public/connectors/github/src/pr-sync.ts`
- Modify: `public/connectors/github/src/github.ts`
- Modify: `public/connectors/github/src/pr-sync.test.ts`

**Interfaces:**
- Consumes: `GitHubIssueComment` shape (existing type in `github.ts`, extended below).
- Produces: `GitHubReviewComment` type (`github.ts`); `fetchReviewComments(source, token, owner, repo, prNumber): Promise<GitHubReviewComment[]>` and `buildReviewCommentNote(source, comment): NewNote`-shaped note builder (`pr-sync.ts`); `recordOpenPRCommentKeys(source, repositoryId, prNumber, keys: string[]): Promise<void>` and `clearOpenPRCommentKeys(source, repositoryId, prNumber): Promise<void>` and `appendOpenPRCommentKey(source, repositoryId, prNumber, key): Promise<void>` (`pr-sync.ts`) — consumed by Task 9's poller via `this.tools.store.list("open_pr_")`-style enumeration.

- [ ] **Step 1: Add the `GitHubReviewComment` type**

In `public/connectors/github/src/github.ts`, add after the existing `GitHubIssueComment` type:

```typescript
export type GitHubReviewComment = {
  id: number;
  body: string;
  created_at: string;
  updated_at: string;
  user: GitHubUser;
  html_url: string;
  /** File path the comment is anchored to. */
  path: string;
  /** Line number in the file (the comment's current position after any diff updates). */
  line: number | null;
  /** Present when this comment is a reply within an existing review-comment thread. */
  in_reply_to_id?: number;
  pull_request_review_id: number;
};
```

- [ ] **Step 2: Write the failing test for the note builder**

Add to `public/connectors/github/src/pr-sync.test.ts`:

```typescript
import { buildReviewCommentNote } from "./pr-sync";
import type { GitHubReviewComment } from "./github";

function makeReviewComment(
  overrides: Partial<GitHubReviewComment> = {}
): GitHubReviewComment {
  return {
    id: 555,
    body: "Should this be async?",
    created_at: "2026-07-01T00:00:00Z",
    updated_at: "2026-07-01T00:00:00Z",
    user: { id: 2, login: "reviewer" },
    html_url: "https://github.com/acme/repo/pull/42#discussion_r555",
    path: "src/foo.ts",
    line: 42,
    pull_request_review_id: 1,
    ...overrides,
  };
}

describe("buildReviewCommentNote", () => {
  const fakeSource = {
    userToContact: (user: { id: number; login: string }) => ({
      email: `${user.id}+${user.login}@users.noreply.github.com`,
      name: user.login,
      source: { accountId: String(user.id) },
    }),
  } as any;

  it("keys the note with the review-comment- prefix", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.key).toBe("review-comment-555");
  });

  it("prefixes content with a file/line header", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.content).toBe("📄 src/foo.ts:42\n\nShould this be async?");
  });

  it("omits the line number from the header when line is null", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment({ line: null }));
    expect(note.content).toBe("📄 src/foo.ts\n\nShould this be async?");
  });

  it("sets reNote by key when the comment is a reply", () => {
    const note = buildReviewCommentNote(
      fakeSource,
      makeReviewComment({ in_reply_to_id: 111 })
    );
    expect(note.reNote).toEqual({ key: "review-comment-111" });
  });

  it("omits reNote when the comment is not a reply", () => {
    const note = buildReviewCommentNote(fakeSource, makeReviewComment());
    expect(note.reNote).toBeUndefined();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `buildReviewCommentNote` not exported.

- [ ] **Step 4: Implement `fetchReviewComments` and `buildReviewCommentNote`**

In `public/connectors/github/src/pr-sync.ts`, add the import `type GitHubReviewComment` to the existing `import type { ... } from "./github";` block, then add:

```typescript
/**
 * Build a Plot note for an inline (code-line) PR review comment. File/line
 * context renders as a short header — not the full diff hunk, to avoid
 * clutter — followed by the comment body. Replies (GitHub's
 * `in_reply_to_id`) map to Plot's native `reNote` threading so they nest
 * under their parent instead of appearing as flat siblings.
 */
export function buildReviewCommentNote(
  source: GitHub,
  comment: GitHubReviewComment
): {
  key: string;
  content: string;
  created: Date;
  author: import("@plotday/twister/plot").NewContact;
  reNote?: { key: string };
} {
  const location = comment.line ? `${comment.path}:${comment.line}` : comment.path;
  const note: {
    key: string;
    content: string;
    created: Date;
    author: import("@plotday/twister/plot").NewContact;
    reNote?: { key: string };
  } = {
    key: `review-comment-${comment.id}`,
    content: `📄 ${location}\n\n${comment.body}`,
    created: new Date(comment.created_at),
    author: source.userToContact(comment.user),
  };
  if (comment.in_reply_to_id) {
    note.reNote = { key: `review-comment-${comment.in_reply_to_id}` };
  }
  return note;
}

/**
 * Fetch every inline review comment on a PR (paginated).
 */
export async function fetchReviewComments(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  prNumber: number
): Promise<GitHubReviewComment[]> {
  const response = await source.githubFetch(
    token,
    `/repos/${owner}/${repo}/pulls/${prNumber}/comments?per_page=100`
  );
  if (!response.ok) return [];
  return response.json();
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS.

- [ ] **Step 6: Wire inline review comments into batch sync (`convertPRToThread`)**

In `convertPRToThread` (`pr-sync.ts`), after the existing "Fetch review summaries" `try` block (around line 218), add:

```typescript
  // Fetch inline (code-line) review comments
  const reviewCommentKeys: string[] = [];
  try {
    const reviewComments = await fetchReviewComments(source, token, owner, repo, pr.number);
    for (const comment of reviewComments) {
      notes.push(buildReviewCommentNote(source, comment));
      reviewCommentKeys.push(`review-comment-${comment.id}`);
    }
  } catch (error) {
    console.error("Error fetching PR review comments:", error);
  }
```

Then, before the function's `return thread;`, add the open-PR comment-key state write (needed by Task 9's poller — only for PRs still open, per the design's 15-min-poll-scoped-to-open-PRs decision):

```typescript
  const commentKeys = notes
    .map((n) => n.key as string)
    .filter((k) => k.startsWith("comment-") || k.startsWith("review-comment-"));
  if (pr.state === "open") {
    await recordOpenPRCommentKeys(source, repositoryId, pr.number, commentKeys);
  } else {
    await clearOpenPRCommentKeys(source, repositoryId, pr.number);
  }
```

Add this call AFTER the `notes.push(...)` calls for comments/reviews/review-comments but it needs `commentKeys` computed from the final `notes` array — place it directly before `const thread: NewLinkWithNotes = {...}` so `notes` is fully populated first.

- [ ] **Step 7: Implement the open-PR comment-key state helpers**

Add to `pr-sync.ts`:

```typescript
function openPRCommentKeysStorageKey(repositoryId: string, prNumber: number): string {
  return `open_pr_comment_keys_${repositoryId}_${prNumber}`;
}

/**
 * Overwrite the full set of comment/review-comment note keys tracked for an
 * open PR. Called by batch sync (converges on every resync) and by the
 * `opened`/`reopened` webhook actions (full re-fetch, since a reopened PR's
 * prior key list was cleared on close).
 */
export async function recordOpenPRCommentKeys(
  source: GitHub,
  repositoryId: string,
  prNumber: number,
  keys: string[]
): Promise<void> {
  await source.set(openPRCommentKeysStorageKey(repositoryId, prNumber), keys);
}

/**
 * Append a single new comment/review-comment key to an open PR's tracked
 * set. Called by the incremental comment-created webhook handlers, which
 * know about exactly one new comment and shouldn't pay for a full re-fetch.
 * No-ops if the PR isn't currently tracked as open (e.g. a comment webhook
 * arriving for a PR this instance hasn't batch-synced yet — the next batch
 * pass or an `opened` webhook will pick it up via `recordOpenPRCommentKeys`).
 */
export async function appendOpenPRCommentKey(
  source: GitHub,
  repositoryId: string,
  prNumber: number,
  key: string
): Promise<void> {
  const storageKey = openPRCommentKeysStorageKey(repositoryId, prNumber);
  const existing = await source.get<string[]>(storageKey);
  if (!existing) return;
  if (existing.includes(key)) return;
  await source.set(storageKey, [...existing, key]);
}

/**
 * Stop tracking a PR's comment keys — called when a PR closes/merges, so
 * the reaction poller (Task 9) naturally excludes it on its next pass.
 */
export async function clearOpenPRCommentKeys(
  source: GitHub,
  repositoryId: string,
  prNumber: number
): Promise<void> {
  await source.clear(openPRCommentKeysStorageKey(repositoryId, prNumber));
}
```

- [ ] **Step 8: Register the `pull_request_review_comment` webhook event and add its handler**

In `github.ts`'s `setupWebhook`, add `"pull_request_review_comment"` to the `events` array (currently `["pull_request", "pull_request_review", "issues", "issue_comment"]`).

In `pr-sync.ts`, add the handler:

```typescript
/**
 * Handle pull_request_review_comment webhook event (inline code-line
 * comments — created/edited/deleted).
 */
export async function handlePRReviewCommentWebhook(
  source: GitHub,
  payload: any,
  repositoryId: string
): Promise<void> {
  const comment: GitHubReviewComment = payload.comment;
  const pr: GitHubPullRequest = payload.pull_request;
  const action: string = payload.action;
  if (!comment || !pr) return;

  const [owner, repo] = repositoryId.split("/");

  if (action === "deleted") {
    // No archive-note API on this connector today for any comment type
    // (top-level comments have the same gap) — out of scope here; the
    // note stays in Plot as historical record, matching existing behavior
    // for deleted top-level PR comments.
    return;
  }

  const note = buildReviewCommentNote(source, comment);

  const thread: NewLinkWithNotes = {
    source: `github:pr:${owner}/${repo}/${pr.number}`,
    type: "pull_request",
    title: pr.title,
    notes: [note as any],
    channelId: repositoryId,
    meta: {
      provider: "github",
      owner,
      repo,
      prNumber: pr.number,
      prNodeId: pr.id,
      syncProvider: "github",
      syncableId: repositoryId,
    },
  };

  await source.saveLink(thread);

  if (action === "created") {
    await appendOpenPRCommentKey(source, repositoryId, pr.number, note.key);
  }
}
```

Wire dispatch in `github.ts`'s `onWebhook`, adding a new branch alongside the existing `issue_comment` handling:

```typescript
    } else if (event === "pull_request_review_comment") {
      if (options.syncPullRequests) {
        await handlePRReviewCommentWebhook(this, payload, repositoryId);
      }
    }
```

Add this as a new `else if` branch before the final closing of the `if (event === "pull_request") {...}` chain (i.e. after the existing `issue_comment` branch, same indentation level). Add `handlePRReviewCommentWebhook` to the import from `./pr-sync` at the top of `github.ts`.

- [ ] **Step 9: Wire the `opened`/`reopened`/`closed` PR-key-state transitions into `handlePRWebhook`**

In `handlePRWebhook` (`pr-sync.ts`, modified in Task 4), after the existing `await source.saveLink(thread);` line, add:

```typescript
  if (action === "opened" || action === "reopened") {
    const [ownerName, repoName] = repositoryId.split("/");
    const [issueComments, reviewComments] = await Promise.all([
      source
        .githubFetch(await source.getToken(repositoryId), `/repos/${ownerName}/${repoName}/issues/${pr.number}/comments?per_page=100`)
        .then((r) => (r.ok ? r.json() : [])),
      fetchReviewComments(source, await source.getToken(repositoryId), ownerName, repoName, pr.number),
    ]);
    const keys = [
      ...issueComments.map((c: { id: number }) => `comment-${c.id}`),
      ...reviewComments.map((c: GitHubReviewComment) => `review-comment-${c.id}`),
    ];
    await recordOpenPRCommentKeys(source, repositoryId, pr.number, keys);
  } else if (pr.state === "closed") {
    await clearOpenPRCommentKeys(source, repositoryId, pr.number);
  }
```

- [ ] **Step 10: Also append on the existing top-level comment webhook**

In `handlePRCommentWebhook` (existing function, modified in Task 4 for `sourceUrl`), after `await source.saveLink(thread);`, add:

```typescript
  if (payload.action === "created") {
    await appendOpenPRCommentKey(source, repositoryId, prNumber, `comment-${comment.id}`);
  }
```

- [ ] **Step 11: Add regression tests**

Add to `pr-sync.test.ts`:

```typescript
describe("handlePRReviewCommentWebhook", () => {
  it("saves a note with the review-comment- key and file/line header", async () => {
    const savedLinks: any[] = [];
    const stored: Record<string, any> = {};
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async (link: any) => {
        savedLinks.push(link);
      },
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRReviewCommentWebhook(
      fakeSource,
      { action: "created", comment: makeReviewComment(), pull_request: makePR() },
      "acme/repo"
    );

    expect(savedLinks).toHaveLength(1);
    expect(savedLinks[0].notes[0].key).toBe("review-comment-555");
    expect(savedLinks[0].notes[0].content).toContain("📄 src/foo.ts:42");
  });

  it("appends the new key to open-PR comment-key state", async () => {
    const stored: Record<string, any> = {
      open_pr_comment_keys_acme_repo_42: ["comment-1"],
    };
    const fakeSource = {
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      saveLink: async () => {},
      get: async (key: string) => stored[key] ?? null,
      set: async (key: string, value: any) => {
        stored[key] = value;
      },
    } as any;

    await handlePRReviewCommentWebhook(
      fakeSource,
      { action: "created", comment: makeReviewComment(), pull_request: makePR() },
      "acme/repo"
    );

    expect(stored["open_pr_comment_keys_acme/repo_42"]).toEqual([
      "review-comment-555",
    ]);
  });
});
```

Note the storage-key format string in the assertion (`open_pr_comment_keys_acme/repo_42`, matching `openPRCommentKeysStorageKey`'s actual `${repositoryId}_${prNumber}` interpolation where `repositoryId` already contains a `/`) — verify against the real implementation and fix the assertion if the key format differs once Step 7 is actually run.

- [ ] **Step 12: Run all tests and typecheck**

Run: `cd public/connectors/github && pnpm test && pnpm exec tsc --noEmit`
Expected: all PASS, 0 type errors.

- [ ] **Step 13: Commit**

```bash
git add public/connectors/github/src/github.ts public/connectors/github/src/pr-sync.ts public/connectors/github/src/pr-sync.test.ts
git commit -m "feat(github): sync inline PR review comments inbound"
```

---

### Task 8: Inline review-comment sync — outbound reply routing

Routes a Plot reply to a `review-comment-*` note to GitHub's review-comment reply endpoint instead of the top-level issue-comment endpoint.

**Files:**
- Modify: `public/connectors/github/src/pr-sync.ts`
- Modify: `public/connectors/github/src/github.ts`
- Modify: `public/connectors/github/src/pr-sync.test.ts`

**Interfaces:**
- Consumes: `commentEndpointForKey` (Task 6).
- Produces: `addReviewCommentReply(source, meta, inReplyToId, body): Promise<{ id: number; body: string } | void>` (`pr-sync.ts`).

- [ ] **Step 1: Write the failing test**

Add to `pr-sync.test.ts`:

```typescript
import { addReviewCommentReply } from "./pr-sync";

describe("addReviewCommentReply", () => {
  it("POSTs to the pulls/comments endpoint with in_reply_to", async () => {
    let capturedPath = "";
    let capturedBody = "";
    const fakeSource = {
      githubFetch: async (_token: string, path: string, options: any) => {
        capturedPath = path;
        capturedBody = options.body;
        return {
          ok: true,
          json: async () => ({ id: 999, body: "Good point" }),
        };
      },
      getToken: async () => "fake-token",
    } as any;

    const result = await addReviewCommentReply(
      fakeSource,
      { owner: "acme", repo: "repo", prNumber: 42 },
      555,
      "Good point"
    );

    expect(capturedPath).toBe("/repos/acme/repo/pulls/42/comments");
    expect(JSON.parse(capturedBody)).toEqual({ body: "Good point", in_reply_to: 555 });
    expect(result).toEqual({ id: 999, body: "Good point" });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `addReviewCommentReply` not exported.

- [ ] **Step 3: Implement `addReviewCommentReply`**

Add to `pr-sync.ts`, near `addPRComment`:

```typescript
/**
 * Reply within an existing inline review-comment thread. GitHub's reply
 * endpoint doesn't need a file/line/commit position — it inherits the
 * parent comment's — which is why only replies (not fresh inline comments)
 * are supported outbound from Plot.
 */
export async function addReviewCommentReply(
  source: GitHub,
  meta: import("@plotday/twister").ThreadMeta,
  inReplyToId: number,
  body: string
): Promise<{ id: number; body: string } | void> {
  const owner = meta.owner as string;
  const repo = meta.repo as string;
  const prNumber = meta.prNumber as number;
  const syncableId = `${owner}/${repo}`;

  if (!owner || !repo || !prNumber) {
    throw new Error("Owner, repo, and prNumber required in thread meta");
  }

  const token = await source.getToken(syncableId);

  const response = await source.githubFetch(
    token,
    `/repos/${owner}/${repo}/pulls/${prNumber}/comments`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body, in_reply_to: inReplyToId }),
    }
  );

  if (!response.ok) {
    throw new Error(
      `Failed to add review comment reply: ${response.status} ${await response.text()}`
    );
  }

  const comment = await response.json();
  if (comment?.id) {
    return { id: comment.id, body: comment.body ?? body };
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS.

- [ ] **Step 5: Route `onNoteCreated`/`onNoteUpdated` in `github.ts`**

Modify `onNoteCreated` (in `github.ts`, existing method): before the existing `if (meta.prNumber) { ... }` branch, add a check for a review-comment reply using `thread.meta.reNoteKey` (the field the runtime populates when a note's `reNote` resolves — confirmed pattern from `google-drive`'s `onNoteCreated`):

```typescript
  async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const body = note.content ?? "";

    const reNoteKey = meta.reNoteKey as string | undefined;
    const reviewParent = commentEndpointForKey(reNoteKey ?? null);
    if (reviewParent?.kind === "review") {
      const result = await addReviewCommentReply(
        this,
        meta,
        Number(reviewParent.commentId),
        body
      );
      if (!result) return;
      return {
        key: `review-comment-${result.id}`,
        externalContent: result.body,
      };
    }

    if (meta.prNumber) {
      const result = await addPRComment(this, meta, body);
      if (!result) return;
      return {
        key: `comment-${result.id}`,
        externalContent: result.body,
      };
    } else if (meta.issueNumber) {
      const result = await addIssueComment(this, meta, body);
      if (!result) return;
      return {
        key: `comment-${result.id}`,
        externalContent: result.body,
      };
    }
  }
```

Add `commentEndpointForKey` and `addReviewCommentReply` to `github.ts`'s imports (`./reactions` and `./pr-sync` respectively).

`onNoteUpdated` already extracts the key via regex `/^comment-(\d+)$/` and calls `updateIssueComment` unconditionally — a `review-comment-*` key won't match that regex today, so edits to inline review comments currently silently no-op (the `if (!match) return;` guard). Extend it:

```typescript
  async onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    if (!note.key) return;
    if (!meta.prNumber && !meta.issueNumber) return;

    const reviewMatch = note.key.match(/^review-comment-(\d+)$/);
    if (reviewMatch) {
      const commentId = Number(reviewMatch[1]);
      if (!Number.isFinite(commentId)) return;
      const result = await updateIssueComment(this, meta, commentId, note.content ?? "");
      if (!result) return;
      return { externalContent: result.body };
    }

    const match = note.key.match(/^comment-(\d+)$/);
    if (!match) return;
    const commentId = Number(match[1]);
    if (!Number.isFinite(commentId)) return;

    const body = note.content ?? "";
    const result = await updateIssueComment(this, meta, commentId, body);
    if (!result) return;
    return {
      externalContent: result.body,
    };
  }
```

This reuses `updateIssueComment` for review-comment edits since GitHub's edit endpoint for both comment kinds is `PATCH /repos/{owner}/{repo}/pulls/comments/{id}` vs `PATCH /repos/{owner}/{repo}/issues/comments/{id}` — check `updateIssueComment`'s current implementation in `issue-sync.ts` before assuming it already branches correctly; if it hardcodes the `issues/comments` path, this reuse is WRONG for review comments and needs its own `updateReviewComment` function mirroring `addReviewCommentReply`'s path pattern instead. Read `issue-sync.ts`'s `updateIssueComment` first and adjust: if it only hits `/issues/comments/{id}`, write a parallel `updateReviewComment` in `pr-sync.ts` that PATCHes `/repos/{owner}/{repo}/pulls/comments/{id}`, and call that instead in the `reviewMatch` branch above.

- [ ] **Step 6: Add regression tests**

Add to `pr-sync.test.ts` (or `github.test.ts` if `onNoteCreated`/`onNoteUpdated` routing is easier to test at that level — check whether a `github.test.ts` file exists after Task 6; if not, add one now testing just this routing logic with a minimal fake `GitHub` instance, following the same `fakeSource` pattern used throughout this plan).

```typescript
describe("onNoteCreated review-comment reply routing", () => {
  it("routes to addReviewCommentReply when reNoteKey is a review-comment key", async () => {
    // Construct a minimal GitHub instance with addReviewCommentReply's
    // dependencies stubbed (githubFetch, getToken) and call
    // github.onNoteCreated(note, thread) directly, asserting the returned
    // NoteWriteBackResult.key starts with "review-comment-" and that the
    // stubbed githubFetch was called with the /pulls/{n}/comments path
    // (not /issues/{n}/comments).
  });

  it("falls back to addPRComment when reNoteKey is absent", async () => {
    // Same setup, thread.meta with no reNoteKey — assert the top-level
    // /issues/{n}/comments path is used instead.
  });
});
```

Write out the actual test bodies once Step 5's exact `GitHub` class shape is in front of you — construct the minimal instance the same way `reactions.test.ts`/`pr-sync.test.ts` already do (plain object literals implementing only the methods exercised), not a full class instantiation (the real `GitHub` class requires the twist runtime's `build()` machinery, which isn't available in a unit test).

- [ ] **Step 7: Run all tests and typecheck**

Run: `cd public/connectors/github && pnpm test && pnpm exec tsc --noEmit`
Expected: all PASS, 0 errors.

- [ ] **Step 8: Commit**

```bash
git add public/connectors/github/src/github.ts public/connectors/github/src/pr-sync.ts public/connectors/github/src/pr-sync.test.ts
git commit -m "feat(github): route review-comment replies to the correct GitHub endpoint"
```

---

### Task 9: Reaction poll job

The recurring, open-PR-scoped inbound reaction poll. Enumerates each open PR's tracked comment keys (Task 7's state), fetches reactions per comment, and reconciles via `setNoteReactions` (Task 3).

**Files:**
- Modify: `public/connectors/github/src/reactions.ts`
- Modify: `public/connectors/github/src/github.ts`
- Modify: `public/connectors/github/src/reactions.test.ts`

**Interfaces:**
- Consumes: `commentEndpointForKey` (Task 6, same file), `GITHUB_REACTION_TO_EMOJI` (Task 5), `recordOpenPRCommentKeys`/`openPRCommentKeysStorageKey` naming convention (Task 7, read via `this.tools.store.list` + `this.get`), `Integrations.setNoteReactions` (Task 3).
- Produces: `pollOpenPRReactions(source: GitHub): Promise<void>` — the `scheduleRecurring` callback entry point, called by `github.ts`.

- [ ] **Step 1: Write the failing test for the per-comment reaction fetch/reconcile**

Add to `reactions.test.ts`:

```typescript
import { reconcileCommentReactions } from "./reactions";

describe("reconcileCommentReactions", () => {
  it("fetches reactions and calls setNoteReactions with the mapped emoji state", async () => {
    const setNoteReactionsCalls: any[] = [];
    const fakeSource = {
      githubFetch: async () => ({
        ok: true,
        json: async () => [
          { id: 1, content: "+1", user: { id: 10, login: "alice" } },
          { id: 2, content: "+1", user: { id: 11, login: "bob" } },
          { id: 3, content: "heart", user: { id: 10, login: "alice" } },
        ],
      }),
      userToContact: (user: { id: number; login: string }) => ({
        email: `${user.id}+${user.login}@users.noreply.github.com`,
        name: user.login,
        source: { accountId: String(user.id) },
      }),
      setNoteReactions: async (...args: any[]) => {
        setNoteReactionsCalls.push(args);
      },
    } as any;

    await reconcileCommentReactions(
      fakeSource,
      "fake-token",
      "acme",
      "repo",
      42,
      "comment-123"
    );

    expect(setNoteReactionsCalls).toHaveLength(1);
    const [thread, key, reactions] = setNoteReactionsCalls[0];
    expect(thread).toEqual({ source: "github:pr:acme/repo/42" });
    expect(key).toBe("comment-123");
    expect(reactions["👍"]).toHaveLength(2);
    expect(reactions["❤️"]).toHaveLength(1);
  });

  it("no-ops for a key with no known GitHub endpoint", async () => {
    const setNoteReactionsCalls: any[] = [];
    const fakeSource = {
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async (...a: any[]) => setNoteReactionsCalls.push(a),
    } as any;

    await reconcileCommentReactions(fakeSource, "fake-token", "acme", "repo", 42, "description");

    expect(setNoteReactionsCalls).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/connectors/github && pnpm test`
Expected: FAIL — `reconcileCommentReactions` not exported.

- [ ] **Step 3: Implement `reconcileCommentReactions`**

Add to `reactions.ts`:

```typescript
type GitHubReactionEntry = { id: number; content: string; user: { id: number; login: string } };

/**
 * Fetch a comment's current reactions from GitHub and reconcile them into
 * Plot via `setNoteReactions` (clear-and-replace — this IS the note's full
 * reaction state, including removals since the last poll).
 */
export async function reconcileCommentReactions(
  source: GitHub,
  token: string,
  owner: string,
  repo: string,
  prNumber: number,
  key: string
): Promise<void> {
  const endpoint = commentEndpointForKey(key);
  if (!endpoint) return;

  let entries: GitHubReactionEntry[];
  try {
    const response = await source.githubFetch(
      token,
      reactionsPath(owner, repo, endpoint.commentId, endpoint.kind)
    );
    if (!response.ok) return;
    entries = await response.json();
  } catch (error) {
    console.warn(`[github] Failed to fetch reactions for ${key}:`, error);
    return;
  }

  const reactions: Record<string, ReturnType<GitHub["userToContact"]>[]> = {};
  for (const entry of entries) {
    const emoji = GITHUB_REACTION_TO_EMOJI[entry.content];
    if (!emoji) continue; // GitHub reaction type we don't map (shouldn't happen — fixed set)
    reactions[emoji] = reactions[emoji] ?? [];
    reactions[emoji].push(source.userToContact(entry.user));
  }

  try {
    await source.setNoteReactions(
      { source: `github:pr:${owner}/${repo}/${prNumber}` },
      key,
      reactions as any
    );
  } catch (error) {
    console.warn(`[github] Failed to reconcile reactions for ${key}:`, error);
  }
}
```

Add the `GITHUB_REACTION_TO_EMOJI` import to `reactions.ts` (it currently only imports `EMOJI_TO_GITHUB_REACTION` from `./github-emoji`) — extend that import to include both.

Note the call is `source.setNoteReactions(...)`, not `source.tools.integrations.setNoteReactions(...)` directly: `GitHub` (the `Connector` subclass) exposes `this.tools.integrations` internally, but `reactions.ts`'s helper functions take a `source: GitHub` parameter and call `source.githubFetch`/`source.userToContact`/`source.getToken`, all of which are `github.ts`'s existing **public wrapper methods** around otherwise-protected functionality. `this.tools` is NOT currently exposed as a public property on `GitHub` — check `github.ts`'s class definition: `build()` returns `{ options, integrations, network, tasks }`, and `this.tools` is inherited from the base `Twist`/`Connector` class as `protected`. Add a public wrapper, mirroring the existing `saveLink`/`createCallback` wrapper pattern in `github.ts`:

```typescript
  /**
   * Set the full reaction state for a note (public wrapper for the
   * protected `this.tools.integrations`, used by reactions.ts).
   */
  async setNoteReactions(
    thread: { id: string } | { source: string },
    key: string,
    reactions: import("@plotday/twister").NewReactions
  ): Promise<void> {
    await this.tools.integrations.setNoteReactions(thread as any, key, reactions);
  }
```

Add this to `github.ts` near the existing `saveLink` wrapper.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS.

- [ ] **Step 5: Implement `pollOpenPRReactions`**

Add to `reactions.ts`:

```typescript
/**
 * Recurring poll entry point (scheduleRecurring callback). Enumerates every
 * repo this connector instance is syncing, then every PR this connector has
 * tracked as open (Task 7's `open_pr_comment_keys_*` state — there is no
 * platform read-back for a connector's own synced links/notes, so this
 * state is the only source of truth for "which PRs are currently open").
 * For each tracked comment key, reconciles its reactions.
 */
export async function pollOpenPRReactions(source: GitHub): Promise<void> {
  const stateKeys = await source.listStoreKeys("open_pr_comment_keys_");
  for (const stateKey of stateKeys) {
    // Format: open_pr_comment_keys_<owner>/<repo>_<prNumber>
    const match = stateKey.match(/^open_pr_comment_keys_(.+)_(\d+)$/);
    if (!match) continue;
    const repositoryId = match[1];
    const prNumber = Number(match[2]);
    const [owner, repo] = repositoryId.split("/");
    if (!owner || !repo) continue;

    const keys = (await source.get<string[]>(stateKey)) ?? [];
    if (keys.length === 0) continue;

    let token: string;
    try {
      token = await source.getToken(repositoryId);
    } catch {
      continue; // token unavailable (needs reauth) — skip this repo this pass
    }

    for (const key of keys) {
      await reconcileCommentReactions(source, token, owner, repo, prNumber, key);
    }
  }
}
```

This depends on a `listStoreKeys` public wrapper on `GitHub` (the underlying `this.tools.store.list` is protected, same issue as Step 3). Add to `github.ts`, next to the `setNoteReactions` wrapper added in Step 3:

```typescript
  /**
   * List stored keys by prefix (public wrapper for the protected
   * `this.tools.store.list`, used by reactions.ts's poll job).
   */
  async listStoreKeys(prefix: string): Promise<string[]> {
    return this.tools.store.list(prefix);
  }
```

Verify `store` is available on `this.tools` without an explicit `build()` entry — per `public/connectors/AGENTS.md`, "The built-in `callbacks`, `store`, and `tasks` tools are always available... and need no `build()` entry," so this should work without modifying `github.ts`'s `build()` method. Confirm by typechecking (Step 8 below) rather than assuming.

- [ ] **Step 6: Write the test for `pollOpenPRReactions`**

Add to `reactions.test.ts`:

```typescript
describe("pollOpenPRReactions", () => {
  it("reconciles reactions for every tracked comment across every open PR", async () => {
    const reconciled: string[] = [];
    const stored: Record<string, string[]> = {
      "open_pr_comment_keys_acme/repo_42": ["comment-1", "review-comment-2"],
      "open_pr_comment_keys_acme/repo_43": ["comment-3"],
    };
    const fakeSource = {
      listStoreKeys: async (prefix: string) =>
        Object.keys(stored).filter((k) => k.startsWith(prefix)),
      get: async (key: string) => stored[key] ?? null,
      getToken: async () => "fake-token",
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async (_thread: any, key: string) => {
        reconciled.push(key);
      },
    } as any;

    await pollOpenPRReactions(fakeSource);

    expect(reconciled.sort()).toEqual(["comment-1", "comment-3", "review-comment-2"]);
  });

  it("skips a repo whose token is unavailable without throwing", async () => {
    const stored: Record<string, string[]> = {
      "open_pr_comment_keys_acme/repo_42": ["comment-1"],
    };
    const fakeSource = {
      listStoreKeys: async (prefix: string) =>
        Object.keys(stored).filter((k) => k.startsWith(prefix)),
      get: async (key: string) => stored[key] ?? null,
      getToken: async () => {
        throw new Error("no token");
      },
      githubFetch: async () => ({ ok: true, json: async () => [] }),
      userToContact: (u: any) => u,
      setNoteReactions: async () => {
        throw new Error("should not be called");
      },
    } as any;

    await expect(pollOpenPRReactions(fakeSource)).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd public/connectors/github && pnpm test`
Expected: PASS.

- [ ] **Step 8: Wire `scheduleRecurring` registration and teardown**

In `github.ts`, add `pollOpenPRReactions` to the import from `./reactions`. Add a callback entry point method (mirroring the existing `syncPRBatch`/`syncIssueBatch` pattern):

```typescript
  /**
   * Callback entry point for the reaction poll (scheduleRecurring target).
   */
  async pollReactions(): Promise<void> {
    await pollOpenPRReactions(this);
  }
```

Register it in `provisionRepo` (the shared setup function called by both `onRepoEnabled` and `onOrgEnabled`'s per-repo loop), after the existing `webhookCallback`/`runTask` lines:

```typescript
    const reactionPollCallback = await this.callback(this.pollReactions);
    await this.scheduleRecurring(`reaction-poll-${repositoryId}`, reactionPollCallback, {
      intervalMs: 15 * 60 * 1000,
    });
```

Tear it down in `teardownRepo` (the shared cleanup called by both `onRepoDisabled` and `onOrgDisabled`'s loop), after the existing `await this.stopSync(repositoryId);` line:

```typescript
    await this.cancelScheduledTask(`reaction-poll-${repositoryId}`);
```

Check whether `cancelScheduledTask` is already a public/inherited method reachable as `this.cancelScheduledTask` (per `public/connectors/AGENTS.md`'s watch-renewal example, it is — `await this.cancelScheduledTask(key);` is shown directly on `this` with no wrapper needed, unlike `scheduleRecurring` which `github.ts` doesn't currently call anywhere, so verify via typecheck that no additional public-wrapper indirection is needed here, unlike Steps 3/5's `tools.*` wrappers).

- [ ] **Step 9: Run all tests and typecheck**

Run: `cd public/connectors/github && pnpm test && pnpm exec tsc --noEmit`
Expected: all PASS, 0 errors.

- [ ] **Step 10: Commit**

```bash
git add public/connectors/github/src/reactions.ts public/connectors/github/src/reactions.test.ts public/connectors/github/src/github.ts
git commit -m "feat(github): poll and reconcile reactions on open PRs every 15 minutes"
```

---

### Task 10: Manual verification (Component 4)

Not a code task — confirms the already-implemented Plot→GitHub note write-back (`onNoteCreated`/`onNoteUpdated` → `addPRComment`/`updateIssueComment`, which predates this plan) actually reaches a real PR now that the connection-drift bug (fixed separately on branch `fix/tic-connection-drift`, commit `6fc5958f7`) is resolved.

**Files:** None — this is a manual runtime check, not a code change.

- [ ] **Step 1: Confirm the connection-drift fix has healed this GitHub connection**

Open the Plot app's connection settings for the GitHub connection used in earlier testing (the one on PR `plotday/plot#277`, per the original bug report). Opening this page triggers `getIntegrationData`'s self-heal (per `fix/tic-connection-drift`). Then verify via the prod-db-investigate skill (readonly) that `twist_instance_connection` now has a row for this instance/owner (repeat the query used earlier in this conversation: join `twist_instance` → `twist` → `twist_instance_connection`).

- [ ] **Step 2: Post a test note on a live PR thread in Plot**

Using the Plot app (local dev, per "Never deploy" — only work locally), open a GitHub PR thread and add a plain-text reply note (no explicit @-mention needed, since the connection now shows `user_connected = true` and the client auto-mentions the source connector).

- [ ] **Step 3: Confirm the comment landed on GitHub**

Check the actual GitHub PR (in the browser) and confirm the new comment appears, matching the Plot note's content.

- [ ] **Step 4: Confirm the round-trip baseline**

Edit the same note in Plot; confirm the edit propagates to the GitHub comment (`onNoteUpdated` → `updateIssueComment`). This exercises the sync-baseline preservation contract (`public/connectors/AGENTS.md` "Sync baseline preservation") — if a subsequent GitHub→Plot resync of that comment overwrites your edit, the baseline isn't matching and is a bug worth filing separately (not in scope to fix here, since this write-back code predates this plan).

No commit for this task — it's a verification checklist, not a code change. If Step 3 or Step 4 fails, stop and report back rather than proceeding — that would mean the pre-existing write-back code has its own bug beyond the connection-drift issue, which is new information requiring its own diagnosis.

---

## Post-plan: `/finalize`

Once all 10 tasks are complete, run `/finalize`:
1. `pnpm lint` repo-wide (or at minimum: `public/connectors/github`, `public/twister`, `workers/api`).
2. Backwards compatibility: confirm `updateIssueComment`'s signature wasn't changed in a way that breaks its existing top-level-comment callers (Task 8 Step 5 either reuses it as-is or adds a new sibling function — reusing without changing its signature is backward compatible by construction).
3. Error capture: `reactions.ts`'s outbound calls (`reactToComment`/`unreactToComment`) use `console.warn` on failure, matching this connector's existing best-effort pattern (`updatePRStatus`, `setupWebhook`) rather than `captureException` — this connector doesn't use PostHog capture anywhere today, so this is consistent, not a gap to fix here.
4. Docs: run `pnpm updates:new` for a user-facing changelog fragment, e.g. under a `### GitHub` section: "PR descriptions and inline code comments now sync automatically, and reactions on GitHub comments sync both ways with Plot." Fixes section: none (this plan is all-new capability, not bug fixes, aside from Task 4's webhook-parity fix, which is worth its own `### Fixes` bullet: "Fixed PRs opened after a GitHub connection was already set up sometimes missing their description or the 'Open in GitHub' link.").
5. Public submodule: every commit in this plan lands in `public/` (the GitHub connector and twister SDK both live there) — per root `AGENTS.md` "Public Repo PRs," rewrite commit messages/PR description for public consumption before opening the PR (they're already written that way in this plan, but re-check for any internal references before pushing). This needs a separate PR against the public repo, not bundled with any private-repo change.
