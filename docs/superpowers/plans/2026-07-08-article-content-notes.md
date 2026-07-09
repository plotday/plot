# Article Content Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user creates a thread whose first note carries a public article link, fetch the page, convert it to Markdown, and add that content as a Plot-authored note — scraping once into a global cache and warming it early at compose time.

**Architecture:** Wire the already-built, idempotent extraction engine (`workers/api/src/extract/*` + `EXTRACT_QUEUE` consumer + `extracted_url` cache + R2 `ARTICLES_BUCKET`) to (1) a client warm-up endpoint `POST /app/extract`, (2) a server hook in `POST /sync/notes` that requests extraction for first-note article links, and (3) durable delivery via a new `extracted_url_injection` table drained by the queue consumer, an immediate re-check, and a cron safety-net. The injected note is authored by the per-user Plot `twist_instance` (same pattern as `addTrialNote`).

**Tech Stack:** Cloudflare Workers (Hono, Kysely/Hyperdrive Postgres, R2, Queues, Durable Objects), Vitest (node unit + real-local-Postgres rollback tests); Flutter/Dart client (http + `debugSetHttpClientFactory`/`MockClient`).

## Global Constraints

- **Local only. Never deploy** (workers included) — run everything against the local/worktree DB.
- **Do the work in a worktree** with an isolated DB (this is a schema change). Create it via `superpowers:using-git-worktrees`, then `bash scripts/worktree-db`. Verify the DB port before any migration: `psql "$DATABASE_URL" -tAc "show port;"` must NOT be `54322` if in a worktree. Commit the approved spec (`docs/superpowers/specs/2026-07-08-article-content-notes-design.md`) and this plan in the first commit.
- **Schema workflow:** edit `libs/db/schema/` only → `pnpm gen-migration -- <name>` → `pnpm apply-migrations` (auto-runs `pnpm types`) → commit the regenerated `libs/db/src/types.ts`. Never edit migrations or `types.ts` by hand.
- **Expand-only migration** (additive table): must pass the Squawk gate — no destructive DDL.
- **Never DELETE rows from synced tables.** (Not an issue here: `extracted_url_injection` is server-only — no `user.*` view, no `seq`, never synced.)
- **Background DB isolation:** never use the request-scoped `c.var.db` inside `waitUntil`/queue/cron. Open a fresh connection (`createDb`/`createFrontendDb`/`withDb`) and destroy it in `finally`.
- **Error capture:** unexpected errors in new `catch` blocks call `captureException` (`tracker.captureException(error)` / `postHog.captureException(error)`). Do NOT capture expected/transient states (extraction `failed`/`auth_required`/`paywalled`, per-row fulfillment retries the cron will re-attempt) — this repo has a history of over-capture.
- **TypeScript:** static imports at top of file; `await` all Kysely calls (use `safeQuery` semantics — let errors propagate or handle explicitly). No `.call()/.apply()/.bind()` on RPC stubs.
- **Flutter:** `forui`/`flutter/widgets.dart` imports only (no `flutter/material.dart`); sentence case for any user-facing text; format Dart with `mcp__dart-mcp__dart_format` (NOT bare `dart format`); lint with `cd apps/plot && flutter analyze`.
- **Docs:** add a plain-language user-facing fragment via `pnpm updates:new "..."`.

---

### Task 1: Schema — `extracted_url_injection` table

**Files:**
- Create: `libs/db/schema/50-tables/31-extracted_url_injection.sql`
- Generated: `libs/db/migrations/<timestamp>_add_extracted_url_injection.sql`, `libs/db/src/types.ts` (regenerated — commit it)

**Interfaces:**
- Produces: table `extracted_url_injection` with columns `id bigint`, `url_hash text`, `thread_id uuid`, `priority_id uuid`, `requested_by uuid`, `status text ('pending'|'fulfilled'|'skipped')`, `created_at`, `updated_at`; `UNIQUE(thread_id, url_hash)`; indexes on `url_hash` and `status`. Kysely type `ExtractedUrlInjection` appears in `libs/db/src/types.ts` and (re-exported) in `workers/api/src/db-types.ts`.

- [ ] **Step 1: Write the schema file**

Create `libs/db/schema/50-tables/31-extracted_url_injection.sql`:

```sql
-- Global, server-only queue of "inject the extracted article for this URL into
-- this thread once ready" requests. Pairs with extracted_url (the URL->markdown
-- cache) so the Plot-authored article note is delivered when extraction
-- completes, even if that happens after the thread was created.
-- Server-only: not exposed via any user.* view, no seq, no archived_at — never
-- synced to clients (mirrors extracted_url).
CREATE TABLE "public"."extracted_url_injection" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "url_hash" text NOT NULL,
    "thread_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "requested_by" uuid NOT NULL,
    "status" text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'fulfilled', 'skipped')),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT "extracted_url_injection_thread_url_unique"
        UNIQUE ("thread_id", "url_hash")
);

CREATE INDEX "extracted_url_injection_url_hash_idx"
    ON "public"."extracted_url_injection" ("url_hash");
CREATE INDEX "extracted_url_injection_status_idx"
    ON "public"."extracted_url_injection" ("status");

CREATE TRIGGER set_extracted_url_injection_updated_at
    BEFORE INSERT OR UPDATE ON "public"."extracted_url_injection"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
```

- [ ] **Step 2: Generate the migration**

Run (from repo root; confirm worktree DB port first):
```bash
psql "$DATABASE_URL" -tAc "show port;"
pnpm gen-migration -- add_extracted_url_injection
```
Expected: a new file in `libs/db/migrations/` containing the `CREATE TABLE` above and no other diffs.

- [ ] **Step 3: Apply the migration + regenerate types**

Run:
```bash
pnpm apply-migrations
```
Expected: migration applies cleanly; `pnpm types` runs automatically and updates `libs/db/src/types.ts`.

- [ ] **Step 4: Verify schema/migration/type sync + grants**

Run:
```bash
pnpm diff-schema-migrations
pnpm --filter @plotday/db run lint
psql "$DATABASE_URL" -tAc "\dp public.extracted_url_injection" | cat
```
Expected: `diff-schema-migrations` reports no differences; db lint passes; the `\dp` output shows `api=arwd` and `readonly=r` privileges (granted automatically by the global `ALTER DEFAULT PRIVILEGES` in `libs/db/schema/10-settings/80-grants.sql`). If the `api` role is missing privileges, add explicit grants to `80-grants.sql` and regenerate the migration.

- [ ] **Step 5: Commit**

```bash
git add libs/db/schema/50-tables/31-extracted_url_injection.sql \
        libs/db/migrations/ libs/db/src/types.ts \
        docs/superpowers/specs/2026-07-08-article-content-notes-design.md \
        docs/superpowers/plans/2026-07-08-article-content-notes.md
git commit -m "feat(extract): add extracted_url_injection table for durable article-note delivery"
```

---

### Task 2: Pure helpers — URL extraction + content cap

**Files:**
- Create: `workers/api/src/extract/inject.ts`
- Test: `workers/api/src/extract/inject.test.ts`

**Interfaces:**
- Produces:
  - `extractArticleUrlsFromActions(actions: unknown): string[]` — returns the `http(s)` URLs from `{ type: "external", url }` entries in a note's `actions` jsonb.
  - `capArticleContent(md: string): string` — byte-caps Markdown to `MAX_ARTICLE_CONTENT_BYTES` with a truncation marker.
  - `MAX_ARTICLE_CONTENT_BYTES = 100_000`, `MAX_ARTICLE_URLS_PER_NOTE = 3`.

- [ ] **Step 1: Write the failing tests**

Create `workers/api/src/extract/inject.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  MAX_ARTICLE_CONTENT_BYTES,
  capArticleContent,
  extractArticleUrlsFromActions,
} from "./inject";

describe("extractArticleUrlsFromActions", () => {
  it("returns http(s) URLs from external actions", () => {
    const actions = [
      { type: "external", title: "A", url: "https://example.com/a" },
      { type: "external", title: "B", url: "http://example.org/b" },
    ];
    expect(extractArticleUrlsFromActions(actions)).toEqual([
      "https://example.com/a",
      "http://example.org/b",
    ]);
  });

  it("ignores non-external actions and non-http urls", () => {
    const actions = [
      { type: "auth", title: "x", url: "https://nope.com" },
      { type: "external", title: "mailto", url: "mailto:a@b.com" },
      { type: "external", title: "app", url: "plot://thread/1" },
      { type: "external", title: "ok", url: "https://ok.com" },
    ];
    expect(extractArticleUrlsFromActions(actions)).toEqual(["https://ok.com"]);
  });

  it("returns [] for null / non-array / malformed input", () => {
    expect(extractArticleUrlsFromActions(null)).toEqual([]);
    expect(extractArticleUrlsFromActions("nope")).toEqual([]);
    expect(extractArticleUrlsFromActions([{ type: "external" }])).toEqual([]);
  });
});

describe("capArticleContent", () => {
  it("returns short content unchanged", () => {
    expect(capArticleContent("# Hi\n\nshort")).toBe("# Hi\n\nshort");
  });

  it("truncates content larger than the byte cap and appends a marker", () => {
    const big = "x".repeat(MAX_ARTICLE_CONTENT_BYTES + 500);
    const capped = capArticleContent(big);
    expect(capped.length).toBeLessThan(big.length);
    expect(capped.endsWith("… (truncated)")).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: FAIL — "Cannot find module './inject'".

- [ ] **Step 3: Write the minimal implementation**

Create `workers/api/src/extract/inject.ts`:

```ts
/**
 * Deliver extracted article Markdown as a Plot-authored note.
 *
 * Pairs the global, URL-keyed extraction cache (`extracted_url` + R2
 * `ARTICLES_BUCKET`) with the `extracted_url_injection` bookkeeping table so a
 * thread that references a public article link gets the article's Markdown
 * added as a note once extraction completes — even if that is after the thread
 * was created.
 */

/** Max bytes of Markdown stored on a single injected note (synced to clients). */
export const MAX_ARTICLE_CONTENT_BYTES = 100_000;

/** Cap on how many article links per first note we act on. */
export const MAX_ARTICLE_URLS_PER_NOTE = 3;

/** Pull http(s) article URLs out of a note's `actions` jsonb. */
export function extractArticleUrlsFromActions(actions: unknown): string[] {
  if (!Array.isArray(actions)) return [];
  const urls: string[] = [];
  for (const action of actions) {
    if (
      action &&
      typeof action === "object" &&
      (action as { type?: unknown }).type === "external" &&
      typeof (action as { url?: unknown }).url === "string" &&
      /^https?:\/\//i.test((action as { url: string }).url)
    ) {
      urls.push((action as { url: string }).url);
    }
  }
  return urls;
}

/** Byte-cap Markdown so an injected note never syncs megabytes. */
export function capArticleContent(md: string): string {
  const bytes = new TextEncoder().encode(md);
  if (bytes.byteLength <= MAX_ARTICLE_CONTENT_BYTES) return md;
  const slice = new TextDecoder("utf-8", { fatal: false }).decode(
    bytes.slice(0, MAX_ARTICLE_CONTENT_BYTES)
  );
  return `${slice}\n\n… (truncated)`;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/extract/inject.ts workers/api/src/extract/inject.test.ts
git commit -m "feat(extract): add pure helpers for article-url detection and content capping"
```

---

### Task 3: DB helpers — register injection + insert Plot note

**Files:**
- Modify: `workers/api/src/extract/inject.ts`
- Test: `workers/api/src/extract/inject.test.ts` (add a real-DB describe block + a rollback harness)

**Interfaces:**
- Consumes: `getPlotTwistInstanceId(db, priorityId)` from `../utils/trial`; `capArticleContent` (Task 2); Kysely `DB` type from `../db-types`.
- Produces:
  - `registerArticleInjection(db: Kysely<DB>, args: { urlHash: string; threadId: string; priorityId: string; requestedBy: string }): Promise<void>` — idempotent insert into `extracted_url_injection`.
  - `insertArticleNote(db: Kysely<DB>, args: { threadId: string; priorityId: string; urlHash: string; markdown: string }): Promise<boolean>` — inserts the Plot-authored note (idempotent by `key = "article:{urlHash}"`); returns `true` iff a row was created.

- [ ] **Step 1: Write the failing tests**

Append to `workers/api/src/extract/inject.test.ts` (add imports at top; add this block below the existing describes):

```ts
import { randomUUID } from "node:crypto";
import { sql, type Kysely } from "kysely";
import { vi } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { insertArticleNote, registerArticleInjection } from "./inject";

// getPlotTwistInstanceId is exercised by trial.ts; here we stub it so tests
// don't need to seed the twist/twist_instance graph. The factory must NOT
// reference module-scope consts (vitest hoists vi.mock above them) — each test
// sets the resolved value via vi.mocked(...).mockResolvedValue(...).
vi.mock("../utils/trial", () => ({
  getPlotTwistInstanceId: vi.fn(),
}));
import { getPlotTwistInstanceId } from "../utils/trial";

const PLOT_INSTANCE_ID = "00000000-0000-0000-0000-0000000000aa";
const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

/** Run `fn` inside a transaction that always rolls back; FK/triggers relaxed. */
async function withRollbackTx(
  fn: (trx: Kysely<DB>) => Promise<void>
): Promise<void> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  try {
    await db.transaction().execute(async (trx) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await fn(trx as unknown as Kysely<DB>);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
}

describe.skipIf(!DATABASE_URL)("registerArticleInjection", () => {
  it("inserts a pending row and is idempotent per (thread_id, url_hash)", async () => {
    await withRollbackTx(async (trx) => {
      const args = {
        urlHash: "hash-" + randomUUID(),
        threadId: randomUUID(),
        priorityId: randomUUID(),
        requestedBy: randomUUID(),
      };
      await registerArticleInjection(trx, args);
      await registerArticleInjection(trx, args); // second call is a no-op

      const rows = await trx
        .selectFrom("extracted_url_injection")
        .selectAll()
        .where("url_hash", "=", args.urlHash)
        .execute();
      expect(rows).toHaveLength(1);
      expect(rows[0].status).toBe("pending");
      expect(rows[0].thread_id).toBe(args.threadId);
    });
  });
});

describe.skipIf(!DATABASE_URL)("insertArticleNote", () => {
  it("inserts a note authored by the Plot instance, idempotent by key", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const threadId = randomUUID();
      const urlHash = "hash-" + randomUUID();

      const first = await insertArticleNote(trx, {
        threadId,
        priorityId: randomUUID(),
        urlHash,
        markdown: "# Title\n\nBody",
      });
      const second = await insertArticleNote(trx, {
        threadId,
        priorityId: randomUUID(),
        urlHash,
        markdown: "# Title\n\nBody",
      });

      expect(first).toBe(true);
      expect(second).toBe(false); // idempotent

      const notes = await trx
        .selectFrom("note")
        .selectAll()
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .execute();
      expect(notes).toHaveLength(1);
      expect(notes[0].created_by).toBe(PLOT_INSTANCE_ID);
      expect(notes[0].author_id).toBe(PLOT_INSTANCE_ID);
      expect(notes[0].content).toBe("# Title\n\nBody");
      expect(notes[0].link_id).toBeNull();
    });
  });

  it("returns false when the user has no Plot instance", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValueOnce(null);
      const result = await insertArticleNote(trx, {
        threadId: randomUUID(),
        priorityId: randomUUID(),
        urlHash: "hash-" + randomUUID(),
        markdown: "x",
      });
      expect(result).toBe(false);
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: FAIL — `registerArticleInjection` / `insertArticleNote` not exported.

- [ ] **Step 3: Write the implementation**

Add to `workers/api/src/extract/inject.ts` (add imports at top of file):

```ts
import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import { getPlotTwistInstanceId } from "../utils/trial";
```

```ts
/** Record that `threadId` wants the article for `urlHash` once it's ready. */
export async function registerArticleInjection(
  db: Kysely<DB>,
  args: {
    urlHash: string;
    threadId: string;
    priorityId: string;
    requestedBy: string;
  }
): Promise<void> {
  await db
    .insertInto("extracted_url_injection")
    .values({
      url_hash: args.urlHash,
      thread_id: args.threadId,
      priority_id: args.priorityId,
      requested_by: args.requestedBy,
      status: "pending",
    })
    .onConflict((oc) => oc.columns(["thread_id", "url_hash"]).doNothing())
    .execute();
}

/**
 * Insert the extracted article Markdown as a note authored by the user's Plot
 * twist instance (so it renders as "Plot"). Idempotent via note.key; a NULL
 * link_id means the partial unique index can't ON CONFLICT, so we pre-check
 * (same as addTrialNote). Returns true iff a note was created.
 */
export async function insertArticleNote(
  db: Kysely<DB>,
  args: {
    threadId: string;
    priorityId: string;
    urlHash: string;
    markdown: string;
  }
): Promise<boolean> {
  const plotTwistInstanceId = await getPlotTwistInstanceId(db, args.priorityId);
  if (!plotTwistInstanceId) return false;

  const key = `article:${args.urlHash}`;
  const existing = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", args.threadId)
    .where("key", "=", key)
    .where("link_id", "is", null)
    .executeTakeFirst();
  if (existing) return false;

  await db
    .insertInto("note")
    .values({
      thread_id: args.threadId,
      content: capArticleContent(args.markdown),
      created_by: plotTwistInstanceId,
      author_id: plotTwistInstanceId,
      key,
    })
    .execute();
  return true;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: PASS (all Task 2 + Task 3 tests). If `DATABASE_URL` is unset the DB blocks skip — ensure it is set to the worktree DB so they actually run.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/extract/inject.ts workers/api/src/extract/inject.test.ts
git commit -m "feat(extract): register injections and insert Plot-authored article notes"
```

---

### Task 4: Fulfillment — deliver or skip waiting threads

**Files:**
- Modify: `workers/api/src/extract/inject.ts`
- Test: `workers/api/src/extract/inject.test.ts`

**Interfaces:**
- Consumes: `insertArticleNote` (Task 3); `env.ARTICLES_BUCKET.get`; `env.SYNC_NOTIFY`; `createLogger` from `@plotday/worker-util`.
- Produces: `fulfillArticleInjection(env: Bindings, db: Kysely<DB>, urlHash: string): Promise<void>` — for a terminal `extracted_url`, injects the note into every `pending` thread (on `completed`) or marks them `skipped` (on `failed`/`auth_required`/`paywalled`); no-op while still in progress. Never throws for per-thread failures (leaves them `pending` for the cron).

- [ ] **Step 1: Write the failing tests**

Append to `workers/api/src/extract/inject.test.ts`:

```ts
import { fulfillArticleInjection } from "./inject";

function fakeEnvWithMarkdown(markdown: string | null) {
  const fetchMock = vi.fn(async () => new Response("ok"));
  return {
    env: {
      ARTICLES_BUCKET: {
        get: vi.fn(async () =>
          markdown === null ? null : { text: async () => markdown }
        ),
      },
      SYNC_NOTIFY: {
        idFromName: () => "fake-do-id",
        get: () => ({ fetch: fetchMock }),
      },
    } as unknown as Bindings,
    fetchMock,
  };
}

describe.skipIf(!DATABASE_URL)("fulfillArticleInjection", () => {
  it("injects the note and marks completed rows fulfilled, then notifies", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      const priorityId = randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://example.com/a",
          url_hash: urlHash,
          status: "completed",
          r2_key: `${urlHash}.md`,
        })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: threadId,
          priority_id: priorityId,
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env, fetchMock } = fakeEnvWithMarkdown("# Hello\n\nWorld");
      await fulfillArticleInjection(env, trx, urlHash);

      const note = await trx
        .selectFrom("note")
        .selectAll()
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .executeTakeFirst();
      expect(note?.content).toBe("# Hello\n\nWorld");

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("fulfilled");
      expect(fetchMock).toHaveBeenCalledOnce();
    });
  });

  it("marks pending rows skipped on a terminal failure (no note)", async () => {
    await withRollbackTx(async (trx) => {
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://paywall.com/a",
          url_hash: urlHash,
          status: "paywalled",
        })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: threadId,
          priority_id: randomUUID(),
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env } = fakeEnvWithMarkdown(null);
      await fulfillArticleInjection(env, trx, urlHash);

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("skipped");
      const note = await trx
        .selectFrom("note")
        .select("id")
        .where("thread_id", "=", threadId)
        .executeTakeFirst();
      expect(note).toBeUndefined();
    });
  });

  it("is a no-op while extraction is still in progress", async () => {
    await withRollbackTx(async (trx) => {
      const urlHash = "hash-" + randomUUID();
      await trx
        .insertInto("extracted_url")
        .values({ url: "https://x.com", url_hash: urlHash, status: "extracting" })
        .execute();
      await trx
        .insertInto("extracted_url_injection")
        .values({
          url_hash: urlHash,
          thread_id: randomUUID(),
          priority_id: randomUUID(),
          requested_by: randomUUID(),
          status: "pending",
        })
        .execute();

      const { env } = fakeEnvWithMarkdown(null);
      await fulfillArticleInjection(env, trx, urlHash);

      const inj = await trx
        .selectFrom("extracted_url_injection")
        .select("status")
        .where("url_hash", "=", urlHash)
        .executeTakeFirst();
      expect(inj?.status).toBe("pending");
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: FAIL — `fulfillArticleInjection` not exported.

- [ ] **Step 3: Write the implementation**

Add to `workers/api/src/extract/inject.ts` (add imports at top):

```ts
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
```

```ts
const TERMINAL_FAILURE: ReadonlyArray<string> = [
  "failed",
  "auth_required",
  "paywalled",
];

/** Best-effort SYNC_NOTIFY poke so a freshly-inserted note appears live. */
async function pingSyncNotify(env: Bindings, priorityId: string): Promise<void> {
  try {
    const id = env.SYNC_NOTIFY.idFromName(priorityId);
    await env.SYNC_NOTIFY.get(id).fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: priorityId }),
      })
    );
  } catch (error) {
    createLogger({ operation: "pingSyncNotify" }).error(
      "Failed to notify sync for article note",
      error as Error
    );
  }
}

/**
 * Drain every thread waiting on `urlHash`. On `completed`, insert the article
 * note per thread and mark it fulfilled; on a terminal failure, mark waiting
 * rows skipped; otherwise no-op. Per-thread errors are logged and left pending
 * (the cron drain retries) so one bad thread never blocks the rest.
 */
export async function fulfillArticleInjection(
  env: Bindings,
  db: Kysely<DB>,
  urlHash: string
): Promise<void> {
  const logger = createLogger({ operation: "fulfillArticleInjection" });

  const record = await db
    .selectFrom("extracted_url")
    .select(["status", "r2_key"])
    .where("url_hash", "=", urlHash)
    .executeTakeFirst();
  if (!record) return;

  const pending = await db
    .selectFrom("extracted_url_injection")
    .select(["id", "thread_id", "priority_id"])
    .where("url_hash", "=", urlHash)
    .where("status", "=", "pending")
    .execute();
  if (pending.length === 0) return;

  if (TERMINAL_FAILURE.includes(record.status)) {
    await db
      .updateTable("extracted_url_injection")
      .set({ status: "skipped" })
      .where("url_hash", "=", urlHash)
      .where("status", "=", "pending")
      .execute();
    return;
  }

  if (record.status !== "completed") return; // still pending / extracting

  const object = await env.ARTICLES_BUCKET.get(record.r2_key ?? `${urlHash}.md`);
  if (!object) {
    // Completed but the blob is missing — leave pending for the cron to retry.
    logger.error("article blob missing for completed extraction", undefined, {
      url_hash: urlHash,
    });
    return;
  }
  const markdown = await object.text();

  for (const row of pending) {
    try {
      const inserted = await insertArticleNote(db, {
        threadId: row.thread_id,
        priorityId: row.priority_id,
        urlHash,
        markdown,
      });
      await db
        .updateTable("extracted_url_injection")
        .set({ status: "fulfilled" })
        .where("id", "=", row.id)
        .execute();
      if (inserted) await pingSyncNotify(env, row.priority_id);
    } catch (error) {
      // Transient — leave this row pending; the cron drain will retry it.
      logger.error("failed to inject article note", error as Error, {
        url_hash: urlHash,
        thread_id: row.thread_id,
      });
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: PASS (Task 2–4 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/extract/inject.ts workers/api/src/extract/inject.test.ts
git commit -m "feat(extract): fulfill waiting threads with article notes on terminal extraction"
```

---

### Task 5: Cron drain — safety-net for stragglers

**Files:**
- Modify: `workers/api/src/extract/inject.ts`
- Test: `workers/api/src/extract/inject.test.ts`

**Interfaces:**
- Consumes: `fulfillArticleInjection` (Task 4).
- Produces: `drainPendingArticleInjections(env: Bindings, db: Kysely<DB>): Promise<void>` — finds distinct `url_hash`es that have `pending` injections AND a terminal `extracted_url` status, and calls `fulfillArticleInjection` for each (bounded to 50 per run). Caller supplies the DB (cron wraps it in `withDb`).

- [ ] **Step 1: Write the failing test**

Append to `workers/api/src/extract/inject.test.ts`:

```ts
import { drainPendingArticleInjections } from "./inject";

describe.skipIf(!DATABASE_URL)("drainPendingArticleInjections", () => {
  it("fulfills completed and skips failed, leaving in-progress pending", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const mk = async (status: string) => {
        const urlHash = "hash-" + randomUUID();
        const threadId = randomUUID();
        await trx
          .insertInto("extracted_url")
          .values({
            url: `https://x.com/${urlHash}`,
            url_hash: urlHash,
            status,
            r2_key: `${urlHash}.md`,
          })
          .execute();
        await trx
          .insertInto("extracted_url_injection")
          .values({
            url_hash: urlHash,
            thread_id: threadId,
            priority_id: randomUUID(),
            requested_by: randomUUID(),
            status: "pending",
          })
          .execute();
        return urlHash;
      };
      const done = await mk("completed");
      const failed = await mk("failed");
      const busy = await mk("extracting");

      const { env } = fakeEnvWithMarkdown("# Body\n\ntext");
      await drainPendingArticleInjections(env, trx);

      const status = async (h: string) =>
        (
          await trx
            .selectFrom("extracted_url_injection")
            .select("status")
            .where("url_hash", "=", h)
            .executeTakeFirst()
        )?.status;
      expect(await status(done)).toBe("fulfilled");
      expect(await status(failed)).toBe("skipped");
      expect(await status(busy)).toBe("pending");
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: FAIL — `drainPendingArticleInjections` not exported.

- [ ] **Step 3: Write the implementation**

Add to `workers/api/src/extract/inject.ts`:

```ts
/**
 * Cron safety-net: drain injection rows whose extraction has reached a terminal
 * status but were never fulfilled (e.g. a transient fulfillment failure). The
 * caller provides the DB connection (the cron wraps this in `withDb`).
 */
export async function drainPendingArticleInjections(
  env: Bindings,
  db: Kysely<DB>
): Promise<void> {
  const rows = await db
    .selectFrom("extracted_url_injection as i")
    .innerJoin("extracted_url as e", "e.url_hash", "i.url_hash")
    .select("i.url_hash")
    .distinct()
    .where("i.status", "=", "pending")
    .where("e.status", "in", [
      "completed",
      "failed",
      "auth_required",
      "paywalled",
    ])
    .limit(50)
    .execute();

  const logger = createLogger({ operation: "drainPendingArticleInjections" });
  for (const row of rows) {
    try {
      await fulfillArticleInjection(env, db, row.url_hash);
    } catch (error) {
      logger.error("drain fulfill failed", error as Error, {
        url_hash: row.url_hash,
      });
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/extract/inject.ts workers/api/src/extract/inject.test.ts
git commit -m "feat(extract): add cron drain for stranded article injections"
```

---

### Task 6: Client warm-up endpoint — `POST /app/extract`

**Files:**
- Create: `workers/api/src/app/extract.ts`
- Modify: `workers/api/src/index.ts` (import + mount)
- Test: `workers/api/src/app/extract.test.ts`

**Interfaces:**
- Consumes: `requestExtraction(env, url)` from `../extract/request`.
- Produces: Hono router (default export) with `POST /extract` → `{ status }` (200) on success, `{ error }` (400) on a missing/invalid URL. Mounted under `appSection` so the full path is `POST /app/extract`.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/app/extract.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";

const requestExtractionMock = vi.fn();
vi.mock("../extract/request", () => ({
  requestExtraction: (...args: unknown[]) => requestExtractionMock(...args),
}));

import extract from "./extract";

function post(body: unknown) {
  return extract.request(
    "/extract",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
    { ARTICLES_BUCKET: {} } as unknown as Record<string, unknown>
  );
}

describe("POST /extract", () => {
  it("returns 400 for a missing or non-http url", async () => {
    requestExtractionMock.mockReset();
    const res = await post({ url: "ftp://nope" });
    expect(res.status).toBe(400);
    expect(requestExtractionMock).not.toHaveBeenCalled();
  });

  it("requests extraction and returns the status", async () => {
    requestExtractionMock.mockReset();
    requestExtractionMock.mockResolvedValue({ status: "pending" });
    const res = await post({ url: "https://example.com/a" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "pending" });
    expect(requestExtractionMock).toHaveBeenCalledWith(
      expect.anything(),
      "https://example.com/a"
    );
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test src/app/extract.test.ts`
Expected: FAIL — "Cannot find module './extract'".

- [ ] **Step 3: Write the endpoint**

Create `workers/api/src/app/extract.ts`:

```ts
import { Hono } from "hono";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { requestExtraction } from "../extract/request";

const extract = new Hono<{ Bindings: Bindings }>();

/**
 * POST /app/extract — idempotently begin (or reuse) extraction of a URL's
 * article content into the global cache. Fired fire-and-forget by the client
 * at compose time to warm the cache before the thread is committed.
 */
extract.post("/extract", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { url?: unknown };
  const url = typeof body.url === "string" ? body.url : null;
  if (!url || !/^https?:\/\//i.test(url)) {
    return c.json({ error: "invalid url" }, 400);
  }
  try {
    const record = await requestExtraction(c.env, url);
    return c.json({ status: record.status });
  } catch (error) {
    createLogger({ operation: "extract-endpoint" }).error(
      "requestExtraction failed",
      error as Error
    );
    c.var.tracker?.captureException?.(error);
    // Warm-up is best-effort; the thread-creation hook re-triggers extraction.
    return c.json({ status: "error" });
  }
});

export default extract;
```

- [ ] **Step 4: Mount the route**

In `workers/api/src/index.ts`, add the import near the other app-router imports (e.g. next to `import linkMetadata from "./app/link-metadata";`):

```ts
import extract from "./app/extract";
```

Then in the `appSection` mount list (next to `appSection.route("/", linkMetadata);`), add:

```ts
appSection.route("/", extract);
```

- [ ] **Step 5: Run the test + typecheck**

Run:
```bash
pnpm --filter @plotday/api test src/app/extract.test.ts
pnpm --filter @plotday/api lint
```
Expected: test PASS (2 tests); lint clean.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/extract.ts workers/api/src/app/extract.test.ts workers/api/src/index.ts
git commit -m "feat(api): add POST /app/extract warm-up endpoint"
```

---

### Task 7: Thread-creation hook — request extraction for first-note links

**Files:**
- Modify: `workers/api/src/extract/inject.ts` (add `handleArticleLinksForNewNote`)
- Modify: `workers/api/src/app/sync/notes.ts` (add a `waitUntil` block)
- Test: `workers/api/src/extract/inject.test.ts`

**Interfaces:**
- Consumes: `requestExtraction` from `../extract/request`; `registerArticleInjection`, `fulfillArticleInjection`, `extractArticleUrlsFromActions`, `MAX_ARTICLE_URLS_PER_NOTE` (Tasks 2–4).
- Produces: `handleArticleLinksForNewNote(env: Bindings, db: Kysely<DB>, args: { noteId: string; threadId: string; priorityId: string; userId: string; actions: unknown }): Promise<void>` — for the first note of a thread carrying public article links, requests extraction, registers durable delivery, and fulfills immediately if already cached.

- [ ] **Step 1: Write the failing tests**

Append to `workers/api/src/extract/inject.test.ts`:

```ts
const requestExtractionMock = vi.fn();
vi.mock("../extract/request", () => ({
  requestExtraction: (...args: unknown[]) => requestExtractionMock(...args),
}));

import { handleArticleLinksForNewNote } from "./inject";

describe.skipIf(!DATABASE_URL)("handleArticleLinksForNewNote", () => {
  it("registers + injects when the URL is already completed", async () => {
    await withRollbackTx(async (trx) => {
      vi.mocked(getPlotTwistInstanceId).mockResolvedValue(PLOT_INSTANCE_ID);
      const urlHash = "hash-" + randomUUID();
      const threadId = randomUUID();
      requestExtractionMock.mockReset();
      requestExtractionMock.mockResolvedValue({
        status: "completed",
        url_hash: urlHash,
      });
      await trx
        .insertInto("extracted_url")
        .values({
          url: "https://example.com/a",
          url_hash: urlHash,
          status: "completed",
          r2_key: `${urlHash}.md`,
        })
        .execute();

      const { env } = fakeEnvWithMarkdown("# Article\n\ntext");
      await handleArticleLinksForNewNote(env, trx, {
        noteId: randomUUID(),
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [
          { type: "external", title: "A", url: "https://example.com/a" },
        ],
      });

      const note = await trx
        .selectFrom("note")
        .select("content")
        .where("thread_id", "=", threadId)
        .where("key", "=", `article:${urlHash}`)
        .executeTakeFirst();
      expect(note?.content).toBe("# Article\n\ntext");
    });
  });

  it("skips terminal-failed URLs without registering", async () => {
    await withRollbackTx(async (trx) => {
      const threadId = randomUUID();
      requestExtractionMock.mockReset();
      requestExtractionMock.mockResolvedValue({
        status: "auth_required",
        url_hash: "hash-" + randomUUID(),
      });
      const { env } = fakeEnvWithMarkdown(null);
      await handleArticleLinksForNewNote(env, trx, {
        noteId: randomUUID(),
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [{ type: "external", title: "x", url: "https://jira.example/x" }],
      });
      const rows = await trx
        .selectFrom("extracted_url_injection")
        .select("id")
        .where("thread_id", "=", threadId)
        .execute();
      expect(rows).toHaveLength(0);
    });
  });

  it("does nothing when the note is not the first note of its thread", async () => {
    await withRollbackTx(async (trx) => {
      const threadId = randomUUID();
      const noteId = randomUUID();
      requestExtractionMock.mockReset();
      // Pre-existing earlier note on the thread.
      await trx
        .insertInto("note")
        .values({
          thread_id: threadId,
          content: "earlier",
          created_by: randomUUID(),
          author_id: randomUUID(),
        })
        .execute();
      const { env } = fakeEnvWithMarkdown(null);
      await handleArticleLinksForNewNote(env, trx, {
        noteId,
        threadId,
        priorityId: randomUUID(),
        userId: randomUUID(),
        actions: [{ type: "external", title: "A", url: "https://example.com/a" }],
      });
      expect(requestExtractionMock).not.toHaveBeenCalled();
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: FAIL — `handleArticleLinksForNewNote` not exported.

- [ ] **Step 3: Write the orchestrator**

Add to `workers/api/src/extract/inject.ts` (add import at top):

```ts
import { requestExtraction } from "./request";
```

```ts
/**
 * For the FIRST note of a thread that carries public article links: request
 * extraction of each link, register durable delivery, and fulfill immediately
 * if the article is already cached. Terminal-failed URLs (auth/paywall/failed)
 * are silently skipped (no note, no row). Called from a `waitUntil` after
 * `upsert_note`, so it opens no request-scoped resources.
 */
export async function handleArticleLinksForNewNote(
  env: Bindings,
  db: Kysely<DB>,
  args: {
    noteId: string;
    threadId: string;
    priorityId: string;
    userId: string;
    actions: unknown;
  }
): Promise<void> {
  const urls = extractArticleUrlsFromActions(args.actions);
  if (urls.length === 0) return;

  // First note only: bail if the thread already has any other (non-archived) note.
  const earlier = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", args.threadId)
    .where("id", "!=", args.noteId)
    .where("archived_at", "is", null)
    .limit(1)
    .executeTakeFirst();
  if (earlier) return;

  for (const url of urls.slice(0, MAX_ARTICLE_URLS_PER_NOTE)) {
    const record = await requestExtraction(env, url);
    if (TERMINAL_FAILURE.includes(record.status)) continue; // silent skip

    await registerArticleInjection(db, {
      urlHash: record.url_hash,
      threadId: args.threadId,
      priorityId: args.priorityId,
      requestedBy: args.userId,
    });
    // Fulfill now if already completed; this also closes the race where the
    // extraction finished between requestExtraction and the register above.
    // Otherwise the queue consumer / cron delivers on completion.
    await fulfillArticleInjection(env, db, record.url_hash);
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm --filter @plotday/api test src/extract/inject.test.ts`
Expected: PASS (all inject tests).

- [ ] **Step 5: Wire the hook into `POST /sync/notes`**

In `workers/api/src/app/sync/notes.ts`, add the import near the top (with the other relative imports):

```ts
import { handleArticleLinksForNewNote } from "../../extract/inject";
```

Then, immediately AFTER the existing AI-analysis `c.executionCtx.waitUntil(...)` block (the one guarded by `if (noteId && !body.draft && !body.archived_at && !isUpdate && !isHeld)`), add this new block. It reuses the same "new, live, user-authored note" gate and snapshots values into locals before the closure:

```ts
  // Auto-attach article content: when the FIRST note of a thread carries a
  // public article link, fetch it and add the readable Markdown as a
  // Plot-authored note (delivered durably once extraction completes).
  const isUserAuthored = !body.created_by || body.created_by === c.var.user.id;
  if (
    noteId &&
    !body.draft &&
    !body.archived_at &&
    !isUpdate &&
    !isHeld &&
    isUserAuthored
  ) {
    const articleActions = body.actions;
    const articleThreadId = body.thread_id as string;
    const articlePriorityId = priorityId;
    const articleUserId = c.var.user.id;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createFrontendDb(c.env);
        try {
          await handleArticleLinksForNewNote(c.env, db, {
            noteId,
            threadId: articleThreadId,
            priorityId: articlePriorityId,
            userId: articleUserId,
            actions: articleActions,
          });
        } catch (error) {
          // Unexpected — the happy path never throws (per-thread failures are
          // swallowed inside fulfillArticleInjection).
          c.var.tracker.captureException(error as Error);
        } finally {
          await db.destroy();
        }
      })()
    );
  }
```

(`priorityId`, `noteId`, `isUpdate`, `isHeld`, `createFrontendDb`, and `c.var.tracker` are all already in scope at this point — see `notes.ts` around the `notifySync(c, priorityId)` call and the AI block.)

- [ ] **Step 6: Typecheck + run affected tests**

Run:
```bash
pnpm --filter @plotday/api lint
pnpm --filter @plotday/api test src/extract/inject.test.ts src/app/sync/notes.test.ts
```
Expected: lint clean; both test files PASS.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/extract/inject.ts workers/api/src/extract/inject.test.ts workers/api/src/app/sync/notes.ts
git commit -m "feat(api): request article extraction on first-note links in POST /sync/notes"
```

---

### Task 8: Queue consumer — fulfill on terminal status

**Files:**
- Modify: `workers/api/src/queue/extract.ts` (call `fulfillArticleInjection` after terminal writes)
- Test: `workers/api/src/queue/extract.test.ts` (mock `../extract/inject`; assert the call)

**Interfaces:**
- Consumes: `fulfillArticleInjection(env, db, urlHash)` (Task 4).
- Produces: no new exports; wiring only.

- [ ] **Step 1: Update the existing queue test (add the mock + assertions)**

In `workers/api/src/queue/extract.test.ts`, add near the other `vi.mock(...)` declarations:

```ts
const fulfillArticleInjectionMock = vi.fn();
vi.mock("../extract/inject", () => ({
  fulfillArticleInjection: (...args: unknown[]) =>
    fulfillArticleInjectionMock(...args),
}));
```

Add `fulfillArticleInjectionMock.mockReset();` to the existing `beforeEach`. Then add a new test in the `processExtractions` describe:

```ts
  it("fulfills waiting article injections after a completed extraction", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("<html>hi</html>", { status: 200 }))
    );
    extractMarkdownMock.mockReturnValue({
      title: "Hello",
      author: "",
      description: "",
      md: `# Hello\n\n${longBody}`,
    });
    const r2 = makeR2();
    const msg = makeMessage({ id: 1, urlHash: "abc" });

    await processExtractions(
      { queue: "extract-development", messages: [msg] } as any,
      makeEnv(r2),
      fakeCtx,
      fakePostHog
    );

    expect(fulfillArticleInjectionMock).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      "abc"
    );
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test src/queue/extract.test.ts`
Expected: FAIL — `fulfillArticleInjectionMock` never called (wiring absent).

- [ ] **Step 3: Wire the consumer**

In `workers/api/src/queue/extract.ts`, add the import at the top:

```ts
import { fulfillArticleInjection } from "../extract/inject";
```

In `runOne`, after the "completed" status UPDATE (the `.set({ status: "completed", ... })...execute()` block), add — still inside the `try`, using the in-scope `db` and `urlHash`:

```ts
    // Deliver the article note to any threads waiting on this URL.
    try {
      await fulfillArticleInjection(env, db, urlHash);
    } catch (fulfillError) {
      logger.error(
        "extract: fulfillArticleInjection failed (completed)",
        fulfillError as Error,
        { url_hash: urlHash }
      );
    }
```

And in the `catch` branch, after the terminal-failure status UPDATE's inner `try/catch` (the `.set({ status: terminalStatus, ... })` block) and BEFORE the `if (!(error instanceof ExtractionFailure)) throw error;` line, add:

```ts
    // Mark any waiting threads skipped now that this URL is terminally failed.
    try {
      await fulfillArticleInjection(env, db, urlHash);
    } catch (fulfillError) {
      logger.error(
        "extract: fulfillArticleInjection failed (terminal)",
        fulfillError as Error,
        { url_hash: urlHash }
      );
    }
```

(Both calls are wrapped so a fulfillment error can never flip a successful extraction to failed, nor mask the original extraction error.)

- [ ] **Step 4: Run the test suite to verify it passes**

Run: `pnpm --filter @plotday/api test src/queue/extract.test.ts`
Expected: PASS (existing tests + the new one). The `vi.mock("../extract/inject")` keeps the fake DB from Task-agnostic; no real DB needed here.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/queue/extract.ts workers/api/src/queue/extract.test.ts
git commit -m "feat(extract): deliver article notes from the extract queue consumer"
```

---

### Task 9: Cron — periodic drain

**Files:**
- Modify: `workers/api/src/index.ts` (`scheduled()` — add an every-tick drain)

**Interfaces:**
- Consumes: `drainPendingArticleInjections(env, db)` (Task 5); `withDb` from `./db`.
- Produces: no new exports; wiring only.

- [ ] **Step 1: Add the import**

In `workers/api/src/index.ts`, add near the top-level imports:

```ts
import { drainPendingArticleInjections } from "./extract/inject";
```

Confirm `withDb` is imported from `./db` (add it to the existing `./db` import if not already present — the cron already uses `withDb` for the stuck-tag cleanup, so it should be there).

- [ ] **Step 2: Add the drain to the `*/5` branch**

In `scheduled()`, in the every-tick section (immediately after the `reconcileMissingEmbeddings` try/catch block), add:

```ts
  // Every tick (~5 min): safety-net delivery of article notes for threads
  // waiting on a URL whose extraction has since reached a terminal status.
  try {
    await withDb(env, (db) => drainPendingArticleInjections(env, db));
  } catch (error) {
    logger.error("Error in article-injection drain sweep", error as Error);
  }
```

- [ ] **Step 3: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: clean. (The drain logic itself is covered by Task 5's test; the cron wiring is a thin, typechecked call.)

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/index.ts
git commit -m "feat(extract): drain stranded article injections on the 5-minute cron"
```

---

### Task 10: Flutter — warm-up call + compose call sites

**Files:**
- Modify: `apps/plot/lib/api/api.dart` (add `warmArticleExtraction`)
- Modify: `apps/plot/lib/page/new_thread.dart` (call it in `_enterLinkMode`)
- Modify: `apps/plot/lib/widget/note_editor.dart` (call it in `_handleUrlPasteWhenEmpty`)
- Test: `apps/plot/test/api/warm_article_extraction_test.dart`

**Interfaces:**
- Produces: top-level `Future<void> warmArticleExtraction(String url)` in `api.dart` — fire-and-forget POST to `${Env.apiRoot}/extract` with `{ "url": url }`, routed through the shared client (mockable via `debugSetHttpClientFactory`), swallowing all errors.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/api/warm_article_extraction_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plot/api/api.dart' as api;

void main() {
  tearDown(() => api.debugSetHttpClientFactory(http.Client.new));

  test('warmArticleExtraction POSTs the url to /extract', () async {
    final captured = <http.Request>[];
    api.debugSetHttpClientFactory(
      () => MockClient((request) async {
        captured.add(request);
        return http.Response('{"status":"pending"}', 200);
      }),
    );

    await api.warmArticleExtraction('https://example.com/a');

    expect(captured, hasLength(1));
    expect(captured.single.method, 'POST');
    expect(captured.single.url.path, endsWith('/extract'));
    expect(
      jsonDecode(captured.single.body),
      equals({'url': 'https://example.com/a'}),
    );
  });

  test('warmArticleExtraction swallows a server error', () async {
    api.debugSetHttpClientFactory(
      () => MockClient((_) async => http.Response('boom', 500)),
    );
    // Must not throw.
    await api.warmArticleExtraction('https://example.com/a');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/api/warm_article_extraction_test.dart`
Expected: FAIL — `warmArticleExtraction` is not defined in `api.dart`.

- [ ] **Step 3: Implement `warmArticleExtraction`**

In `apps/plot/lib/api/api.dart`, add (near `getHeaders`/`sendWithReconnect`; `jsonEncode`, `Env`, `sendWithReconnect`, `getHeaders` are all already available in this file):

```dart
/// Fire-and-forget: ask the API to begin (or reuse) extraction of [url]'s
/// article content into the global cache, warming it before the thread is
/// committed so the article note appears with minimal delay. Safe to call
/// repeatedly; all errors are swallowed (the server also triggers extraction
/// on thread creation, so a failure here only costs latency, not correctness).
Future<void> warmArticleExtraction(String url) async {
  try {
    final headers = await getHeaders();
    await sendWithReconnect(
      (client) => client
          .post(
            Uri.parse('${Env.apiRoot}/extract'),
            headers: headers,
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 10)),
      idempotent: true,
    );
  } catch (_) {
    // Best-effort warm-up.
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/api/warm_article_extraction_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the compose call sites**

In `apps/plot/lib/page/new_thread.dart`, ensure `warmArticleExtraction` is imported (add to an existing `package:plot/api/api.dart` import `show` clause, or add `import 'package:plot/api/api.dart' show warmArticleExtraction;`). Then in `_enterLinkMode`:

```dart
  void _enterLinkMode(String url) {
    setState(() => _pendingLink = LinkChipData(url: url));
    unawaited(_resolvePendingLinkMetadata(url));
    unawaited(warmArticleExtraction(url));
  }
```

In `apps/plot/lib/widget/note_editor.dart`, import `warmArticleExtraction` (from `package:plot/api/api.dart`), then in `_handleUrlPasteWhenEmpty`, immediately after the placeholder is attached:

```dart
  Future<void> _handleUrlPasteWhenEmpty(String url) async {
    final placeholder = ExternalUserAction(title: url, url: url);
    _setCurrentActions([..._currentActions, placeholder]);
    unawaited(warmArticleExtraction(url));

    final metadata = await fetchUrlMetadata(url);
    // ...unchanged...
```

(`unawaited` is from `dart:async`, already used in both files.)

- [ ] **Step 6: Analyze + format**

Run:
```bash
cd apps/plot && flutter analyze
```
Then format the touched files with the dart-mcp formatter (NOT bare `dart format`): call `mcp__dart-mcp__dart_format` on `apps/plot/lib/api/api.dart`, `apps/plot/lib/page/new_thread.dart`, `apps/plot/lib/widget/note_editor.dart`, `apps/plot/test/api/warm_article_extraction_test.dart`.
Expected: analyze reports no new issues.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/api/api.dart apps/plot/lib/page/new_thread.dart \
        apps/plot/lib/widget/note_editor.dart apps/plot/test/api/warm_article_extraction_test.dart
git commit -m "feat(app): warm article extraction when a link is added while composing"
```

---

### Task 11: Docs + end-to-end verification + finalize

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Modify: `docs/features.md` (if warranted)

- [ ] **Step 1: Add the user-facing update fragment**

Run:
```bash
pnpm updates:new "Share or paste an article link when starting a thread and Plot adds the article's text to the thread for you"
```
Edit the generated fragment so the bullet lives under an existing feature section that fits (e.g. `### Starting a thread`), plain language, sentence case. Example bullet:

```markdown
### Starting a thread

- Share or paste a link to an article and Plot now adds the article's text to the thread automatically, so you can read it without leaving Plot.
```

- [ ] **Step 2: Update `docs/features.md` if the capability is notable**

Add a short line describing automatic article capture on thread creation under the relevant feature area.

- [ ] **Step 3: End-to-end verification in the real app**

Invoke the `run-app` skill to launch Plot.app against the worktree. Then:
1. Start a new thread and paste a public article URL (e.g. an MDN or Wikipedia page) into the compose flow.
2. Confirm (network/console) that `POST /app/extract` fires at paste/share time.
3. Submit the thread. Within a few seconds a note authored by **Plot** (Plot name + logo avatar) appears containing the article's Markdown.
4. Repeat with an auth-walled URL (e.g. a Jira/Linear link) and confirm NO note is added (silent skip).

Record what you observed (per `superpowers:verification-before-completion` — evidence before claims).

- [ ] **Step 4: Run the finalize checklist**

Invoke the `/finalize` skill. Ensure:
- `pnpm --filter @plotday/api lint` and `cd apps/plot && flutter analyze` are clean.
- `pnpm --filter @plotday/api test` passes (with `DATABASE_URL` pointed at the worktree DB so the inject DB tests run, not skip).
- Backwards compatibility: additive endpoint/table/notes only — confirm no existing sync contract changed.
- Error capture: the only new `captureException` is the notes.ts hook's top-level catch; transient per-thread/extraction states are intentionally logged, not captured.
- Docs fragment present.

- [ ] **Step 5: Commit**

```bash
git add docs/updates.d/ docs/features.md
git commit -m "docs: note automatic article capture on thread creation"
```

---

## Self-Review notes (author)

- **Spec coverage:** Component 1 → Task 6 + 10; Component 2 → Task 7; Component 3 (table) → Task 1, (fulfillment) → Task 4, (consumer driver) → Task 8, (re-check) → Task 7 Step 3, (cron) → Task 5 + 9; Component 4 → Task 3 (+ cap in Task 2). Scope guards (first-note/user-authored/live/public) → Tasks 7 + 2. Freshness "cache indefinitely" → inherited from unchanged `requestExtraction`. Docs → Task 11.
- **Type consistency:** `fulfillArticleInjection(env, db, urlHash)`, `registerArticleInjection(db, args)`, `insertArticleNote(db, args)`, `handleArticleLinksForNewNote(env, db, args)`, `drainPendingArticleInjections(env, db)` — signatures used identically across tasks and callers (notes hook, queue consumer, cron). `requestExtraction` returns `{ status, url_hash, ... }` (`ExtractedUrlRecord`) — consumed by name in Task 7.
- **No client read-back endpoint, no `AddThreadWithLink`/`/sync/links` hook, no TTL/ETag** — intentionally out of scope per the spec.
