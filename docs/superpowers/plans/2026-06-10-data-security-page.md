# Data & Security Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a truthful Data & Security page at plot.day/security, with the hardening changes (token encryption at rest, automated account deletion, vulnerability disclosure, dependency scanning, subprocessor cleanup) that back every claim.

**Architecture:** Token encryption happens at the single chokepoint all consumers share — the `Storage` Durable Object (`workers/api/src/state/storage.ts`) — keyed on the `auth_token:` prefix, with a legacy-plaintext fallback. Account purge is a daily cron sweep that reuses the existing disconnect/uninstall primitives (`removeIntegrationAccount`, `archiveAndDeleteTwist`, `deleteHostedAccountsForInstance`), then deletes the Clerk user and the DB `user` row (cascades). The page is a static React Router route on apps/site following the privacy.tsx pattern.

**Tech Stack:** Cloudflare Workers (Hono, Kysely, DO SQLite), Web Crypto AES-256-GCM, Atlas migrations, React Router v7 + Mantine, vitest.

**Spec:** `docs/superpowers/specs/2026-06-10-data-security-page-design.md`

**Worktree:** `.claude/worktrees/data-security-page`, DB port **54331**. The ambient `$DATABASE_URL` is STALE (54322 = main repo). Every DB command must use
`DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres"` explicitly.

**Known pre-existing failure (do not chase):** `workers/api/src/app/sync/thread-unread.test.ts > read_at record marks the thread read` fails on fresh replayed DBs, passes on the main repo DB. Unrelated to this work.

---

### Task 1: Remove vestigial Supabase env entries

**Files:**
- Modify: `.env.production:11-12`

- [ ] **Step 1: Verify nothing uses them**

Run: `grep -rn "SUPABASE" workers/*/src apps/site/app libs/*/src scripts/ --include="*.ts" --include="*.tsx" 2>/dev/null | grep -v node_modules`
Expected: no output (only `.env.production` and stale `.wrangler/tmp` build artifacts reference it).

- [ ] **Step 2: Delete the two lines from `.env.production`**

Remove exactly:

```
SUPABASE_URL=op://Production/Supabase/API/url
SUPABASE_ANON_KEY=op://Production/Supabase/API/public key
```

(and the blank line that would be left doubled, if any).

- [ ] **Step 3: Commit**

```bash
git add .env.production
git commit -m "chore: remove vestigial Supabase env entries

No source code reads SUPABASE_URL/SUPABASE_ANON_KEY. Removing so the
published subprocessor list on the new security page is exactly true.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: security.txt

**Files:**
- Create: `apps/site/public/.well-known/security.txt`

- [ ] **Step 1: Create the file** (RFC 9116; `Expires` is required)

```
Contact: mailto:security@plot.day
Expires: 2027-06-10T00:00:00.000Z
Preferred-Languages: en
Canonical: https://plot.day/.well-known/security.txt
Policy: https://plot.day/security
```

- [ ] **Step 2: Commit**

```bash
git add apps/site/public/.well-known/security.txt
git commit -m "feat(site): publish security.txt for vulnerability disclosure

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Dependabot configuration

**Files:**
- Create: `.github/dependabot.yml`

- [ ] **Step 1: Create the config**

```yaml
# Dependency vulnerability monitoring. Version-update PRs are grouped and
# capped to stay low-noise; security update PRs are controlled by the repo's
# Dependabot security settings (enable in GitHub repo settings).
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 3
    groups:
      npm-minor-and-patch:
        update-types:
          - "minor"
          - "patch"
  - package-ecosystem: "pub"
    directory: "/apps/plot"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 3
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 3
```

- [ ] **Step 2: Commit**

```bash
git add .github/dependabot.yml
git commit -m "chore: add Dependabot config for npm, pub, and GitHub Actions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Token-encryption helpers (TDD)

**Files:**
- Create: `workers/api/src/utils/token-encryption.ts`
- Test: `workers/api/src/utils/token-encryption.test.ts`

Envelope format stored in the DO: `{"__enc":1,"iv":"<b64>","data":"<b64>"}`.
Legacy values (SuperJSON/JSON strings) never start with `{"__enc"`, so the
prefix check is unambiguous.

- [ ] **Step 1: Write the failing test**

`workers/api/src/utils/token-encryption.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  isTokenKey,
  openTokenValue,
  sealTokenValue,
} from "./token-encryption";

// 64-char hex (256-bit) test keys
const KEY = "a".repeat(64);
const OTHER_KEY = "b".repeat(64);

describe("isTokenKey", () => {
  it("matches auth_token-prefixed keys only", () => {
    expect(isTokenKey("auth_token:google:abc")).toBe(true);
    expect(isTokenKey("channel_config:google:abc")).toBe(false);
    expect(isTokenKey("")).toBe(false);
  });
});

describe("sealTokenValue / openTokenValue", () => {
  it("round-trips a value through the envelope", async () => {
    const plaintext = JSON.stringify({ json: { access_token: "secret-token" } });
    const sealed = await sealTokenValue(plaintext, KEY);
    expect(sealed).not.toContain("secret-token");
    expect(JSON.parse(sealed).__enc).toBe(1);
    const opened = await openTokenValue(sealed, KEY);
    expect(opened).toBe(plaintext);
  });

  it("passes plaintext through unchanged when no key is configured", async () => {
    const plaintext = '{"json":{"access_token":"legacy"}}';
    expect(await sealTokenValue(plaintext, undefined)).toBe(plaintext);
  });

  it("returns legacy (non-envelope) values unchanged on open", async () => {
    const legacy = '{"json":{"access_token":"legacy"}}';
    expect(await openTokenValue(legacy, KEY)).toBe(legacy);
    expect(await openTokenValue(legacy, undefined)).toBe(legacy);
  });

  it("returns null when an envelope can't be opened", async () => {
    const sealed = await sealTokenValue("secret", KEY);
    // Envelope but no key configured
    expect(await openTokenValue(sealed, undefined)).toBeNull();
    // Envelope but wrong key
    expect(await openTokenValue(sealed, OTHER_KEY)).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd workers/api && npx vitest run src/utils/token-encryption.test.ts`
Expected: FAIL — module `./token-encryption` not found.

- [ ] **Step 3: Implement**

`workers/api/src/utils/token-encryption.ts`:

```ts
/**
 * Application-level encryption for connection auth tokens stored in the
 * Storage Durable Object. Applied transparently by Storage.get/set for keys
 * under the `auth_token:` prefix, on top of Cloudflare's infrastructure
 * encryption at rest.
 *
 * Stored envelope: {"__enc":1,"iv":"<b64>","data":"<b64>"}. Legacy values are
 * SuperJSON/JSON strings that can never start with `{"__enc"`, so detection
 * is unambiguous and pre-existing plaintext tokens keep working; they become
 * encrypted the next time they are written (e.g. on token refresh).
 */
import { decrypt, encrypt } from "./encryption";

export const TOKEN_KEY_PREFIX = "auth_token:";

export function isTokenKey(key: string): boolean {
  return key.startsWith(TOKEN_KEY_PREFIX);
}

type TokenEnvelope = { __enc: 1; iv: string; data: string };

function parseEnvelope(raw: string): TokenEnvelope | null {
  if (!raw.startsWith('{"__enc"')) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<TokenEnvelope>;
    if (
      parsed.__enc === 1 &&
      typeof parsed.iv === "string" &&
      typeof parsed.data === "string"
    ) {
      return parsed as TokenEnvelope;
    }
  } catch {
    // fall through — treat as legacy plaintext
  }
  return null;
}

/**
 * Encrypt a serialized token value for storage. Passthrough when no key is
 * configured so a missing secret degrades to today's behavior instead of
 * breaking auth.
 */
export async function sealTokenValue(
  plaintext: string,
  hexKey: string | undefined
): Promise<string> {
  if (!hexKey) return plaintext;
  const { ciphertext, iv } = await encrypt(plaintext, hexKey);
  const envelope: TokenEnvelope = { __enc: 1, iv, data: ciphertext };
  return JSON.stringify(envelope);
}

/**
 * Decrypt a stored token value.
 * - envelope + key → plaintext (null if decryption fails)
 * - envelope + no key → null (unrecoverable; caller treats as missing)
 * - legacy plaintext → returned unchanged
 */
export async function openTokenValue(
  stored: string,
  hexKey: string | undefined
): Promise<string | null> {
  const envelope = parseEnvelope(stored);
  if (!envelope) return stored;
  if (!hexKey) return null;
  try {
    return await decrypt(envelope.data, envelope.iv, hexKey);
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd workers/api && npx vitest run src/utils/token-encryption.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/utils/token-encryption.ts workers/api/src/utils/token-encryption.test.ts
git commit -m "feat(api): AES-256-GCM envelope helpers for stored connection tokens

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Encrypt tokens in the Storage DO + env plumbing

**Files:**
- Modify: `workers/api/src/state/storage.ts` (class declaration + `get` + `set`)
- Modify: `workers/api/src/env.ts` (~line 232, next to `AI_KEY_ENCRYPTION_KEY`)
- Modify: `.env.development` (add dev key near `AI_KEY_ENCRYPTION_KEY` line 18)
- Modify: `.env.production` (add `op://` reference near `AI_KEY_ENCRYPTION_KEY`)
- Modify: `workers/api/package.json` (append to `deploy_vars`)

Why the DO: every consumer of `auth_token:*` values (the `Store` tool used by
integrations.ts / network.ts / unipile/messaging.ts, AND the raw
`storageDO.get` read in `state/privacy-reporting.ts:285`) goes through this
one class, so no call sites change and future consumers are covered.

- [ ] **Step 1: Update `storage.ts`**

Change the class declaration and imports (top of file):

```ts
import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import {
  isTokenKey,
  openTokenValue,
  sealTokenValue,
} from "../utils/token-encryption";

export class Storage extends DurableObject<Bindings> {
```

Replace `get` (currently sync, lines 39-57) with:

```ts
  async get(key: string): Promise<string | null> {
    const logger = createLogger({
      durable_object: "Storage",
      operation: "get",
    });

    try {
      const result = this.sql
        .exec("SELECT value FROM store WHERE key = ?", [key])
        .next();
      if (result.done) {
        return null;
      }
      const raw = result.value.value as string;
      if (!isTokenKey(key)) {
        return raw;
      }
      const opened = await openTokenValue(raw, this.env.TOKEN_ENCRYPTION_KEY);
      if (opened === null) {
        // Unrecoverable (missing/rotated key or corrupt envelope). Treat as
        // absent so the caller prompts re-auth instead of parsing garbage.
        logger.error(
          "Failed to open encrypted token value",
          new Error("Token decryption failed"),
          { key }
        );
      }
      return opened;
    } catch (error) {
      logger.error("Store get error", error as Error, { key });
      throw error;
    }
  }
```

Replace `set` (currently sync, lines 59-70) with:

```ts
  async set(key: string, value: string): Promise<void> {
    const stored = isTokenKey(key)
      ? await sealTokenValue(value, this.env.TOKEN_ENCRYPTION_KEY)
      : value;
    this.sql.exec(
      `
          INSERT INTO store (key, value) 
          VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET 
            value = excluded.value
        `,
      key,
      stored
    );
  }
```

Note: callers already `await` these via DO RPC, so the sync→async change is
transparent. Do not change `list`/`clear`/locks (keys only, no values).

- [ ] **Step 2: Add the binding type in `env.ts`**

Directly after `readonly AI_KEY_ENCRYPTION_KEY: string;` (line 232):

```ts
  // AES-256-GCM key (64-char hex) for app-level encryption of stored
  // connection tokens. Optional: when unset, tokens are stored without the
  // app-level layer (infrastructure encryption still applies) so a missing
  // secret can't break auth.
  readonly TOKEN_ENCRYPTION_KEY?: string;
```

- [ ] **Step 3: Env plumbing**

Generate a dev key: `openssl rand -hex 32`

`.env.development` — add below the `AI_KEY_ENCRYPTION_KEY` line:

```
TOKEN_ENCRYPTION_KEY=<generated hex>
```

`.env.production` — add below `AI_KEY_ENCRYPTION_KEY=op://Production/Database/Encryption Keys/ai`:

```
TOKEN_ENCRYPTION_KEY=op://Production/Database/Encryption Keys/token
```

`workers/api/package.json` — append ` TOKEN_ENCRYPTION_KEY` to the
`deploy_vars` string (line 9).

Also regenerate the local rendered `.dev.vars` so the dev worker picks it up:
run `pnpm get-env` if available, or append the same `TOKEN_ENCRYPTION_KEY=<generated hex>`
line to `workers/api/.dev.vars` manually (file is gitignored).

- [ ] **Step 4: Typecheck and full unit suite**

Run: `cd workers/api && pnpm lint`
Expected: clean (tsc + eslint).

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm test`
Expected: same results as baseline (428+6 pass; only the known pre-existing thread-unread failure).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/state/storage.ts workers/api/src/env.ts .env.development .env.production workers/api/package.json
git commit -m "feat(api): encrypt connection auth tokens at rest in the Storage DO

All auth_token:* values are AES-256-GCM sealed on write and opened on read
at the Storage DO boundary — the single chokepoint shared by the Store tool
and the raw privacy-reporting reader. Legacy plaintext values keep working
and become encrypted on next write (token refresh). Missing key degrades to
plaintext with a warning instead of breaking auth.

Go-live: provision op://Production/Database/Encryption Keys/token and push
worker secrets before relying on the new layer.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Migration — `user.deletion_requested_at`

**Files:**
- Modify: `libs/db/schema/50-tables/10-user.sql`
- Generated: `libs/db/migrations/<timestamp>_user_deletion_requested_at.sql`, `libs/db/migrations/atlas.sum`, `libs/db/src/types.ts`

- [ ] **Step 1: Edit the schema file**

In `libs/db/schema/50-tables/10-user.sql`, add after the `"avatar_url" text,` line:

```sql
    -- Set when the user requests account deletion (DELETE /account). The
    -- daily purge cron permanently erases the account once this is older
    -- than the 14-day recovery window. Cleared by support to cancel.
    "deletion_requested_at" timestamp with time zone,
```

- [ ] **Step 2: Generate the migration**

```bash
cd <worktree root>
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm gen-migration -- user_deletion_requested_at
```

Expected: new file in `libs/db/migrations/` containing only
`ALTER TABLE "public"."user" ADD COLUMN "deletion_requested_at" timestamptz NULL;` (plus comment).

- [ ] **Step 3: Apply locally (regenerates types)**

```bash
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm apply-migrations
```

Expected: migration applies; `pnpm types` runs automatically; `libs/db/src/types.ts` gains `deletion_requested_at` on `user`.

- [ ] **Step 4: Verify schema/migrations in sync**

```bash
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm diff-schema-migrations
```

Expected: no differences.

- [ ] **Step 5: Commit (schema + migration + atlas.sum + types.ts together)**

```bash
git add libs/db/schema/50-tables/10-user.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add user.deletion_requested_at for automated account purge

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `DELETE /account` records the deletion request

**Files:**
- Modify: `workers/api/src/app/account.ts` (route at line 810; insert after the Step 3b ban block ~line 916-930; email copy ~line 948/959)

- [ ] **Step 1: Record the request**

After the Step 3b ban try/catch block (after the `catch (banError) {...}` closes) and before the Step 5 email, insert:

```ts
    // Step 4: Record the deletion request. The daily purge cron permanently
    // erases the account once this is 14+ days old (scheduled/purge-deleted-accounts.ts).
    await c.var.db
      .updateTable("user")
      .set({ deletion_requested_at: new Date().toISOString() })
      .where("id", "=", user.id)
      .execute();
```

(No try/catch: if this fails the whole handler 500s and the user retries —
better than a deactivated account that never gets purged.)

- [ ] **Step 2: Update the notification email copy**

Replace in the HTML body:

```
<p>The account has been deactivated. Please complete manual data deletion within 14 days.</p>
```

with:

```
<p>The account has been deactivated and will be permanently deleted automatically on the scheduled date above. No manual action needed; to cancel (user changed their mind), unban the user in Clerk and clear user.deletion_requested_at.</p>
```

and in the text body replace:

```
The account has been deactivated. Please complete manual data deletion within 14 days.
```

with:

```
The account has been deactivated and will be permanently deleted automatically on the scheduled date above. No manual action needed; to cancel (user changed their mind), unban the user in Clerk and clear user.deletion_requested_at.
```

- [ ] **Step 3: Typecheck**

Run: `cd workers/api && pnpm lint`
Expected: clean. (`deletion_requested_at` exists in types from Task 6.)

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/app/account.ts
git commit -m "feat(api): DELETE /account schedules automated permanent deletion

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Purge job (TDD)

**Files:**
- Create: `workers/api/src/scheduled/purge-deleted-accounts.ts`
- Test: `workers/api/src/scheduled/purge-deleted-accounts.test.ts`

Reuses the app's own removal primitives so connector lifecycle callbacks run
exactly as if the user disconnected things by hand (mirrors
`enforcePersonalPlanLimits` in `twist/management.ts:1360` and the uninstall
flow in `app/twists.ts:48`).

- [ ] **Step 1: Write the failing tests**

`workers/api/src/scheduled/purge-deleted-accounts.test.ts`
(DB harness mirrors `src/state/email-digest-query.test.ts`: real DB via
`process.env.DATABASE_URL`, seed inside a transaction, throw `Rollback`):

```ts
import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import {
  findUsersToPurge,
  purgeUserFiles,
  type FileBucket,
} from "./purge-deleted-accounts";

const DATABASE_URL = process.env.DATABASE_URL;

/** Sentinel thrown to force the seeding transaction to roll back. */
class Rollback extends Error {}

describe("findUsersToPurge (DB)", () => {
  it("returns only users whose deletion request is older than 14 days", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    const expired = randomUUID();
    const recent = randomUUID();
    const none = randomUUID();

    let ids: string[] = [];
    try {
      await db.transaction().execute(async (trx: Kysely<DB>) => {
        await sql`SET LOCAL session_replication_role = replica`.execute(trx);
        await sql`INSERT INTO "user" (id, email, deletion_requested_at)
          VALUES (${expired}::uuid, ${`purge-${expired}@example.test`}, now() - interval '15 days')`.execute(trx);
        await sql`INSERT INTO "user" (id, email, deletion_requested_at)
          VALUES (${recent}::uuid, ${`purge-${recent}@example.test`}, now() - interval '2 days')`.execute(trx);
        await sql`INSERT INTO "user" (id, email)
          VALUES (${none}::uuid, ${`purge-${none}@example.test`})`.execute(trx);

        ids = (await findUsersToPurge(trx)).map((u) => u.id);
        throw new Rollback();
      });
    } catch (error) {
      if (!(error instanceof Rollback)) throw error;
    } finally {
      await db.destroy();
    }

    expect(ids).toContain(expired);
    expect(ids).not.toContain(recent);
    expect(ids).not.toContain(none);
  });
});

describe("purgeUserFiles", () => {
  function fakeBucket(pages: Array<Array<{ key: string; uploadedBy?: string }>>) {
    const deleted: string[] = [];
    let call = 0;
    const bucket: FileBucket = {
      async list() {
        const objects = (pages[call] ?? []).map((o) => ({
          key: o.key,
          customMetadata: o.uploadedBy ? { uploadedBy: o.uploadedBy } : undefined,
        }));
        call++;
        const truncated = call < pages.length;
        return truncated
          ? { objects, truncated: true as const, cursor: String(call) }
          : { objects, truncated: false as const };
      },
      async delete(keys: string | string[]) {
        deleted.push(...(Array.isArray(keys) ? keys : [keys]));
      },
    };
    return { bucket, deleted };
  }

  it("deletes only the user's files, across pages", async () => {
    const { bucket, deleted } = fakeBucket([
      [
        { key: "files/a/one.png", uploadedBy: "user-1" },
        { key: "files/b/two.png", uploadedBy: "user-2" },
      ],
      [
        { key: "files/c/three.png", uploadedBy: "user-1" },
        { key: "files/d/orphan.png" },
      ],
    ]);

    const count = await purgeUserFiles(bucket, "user-1");

    expect(count).toBe(2);
    expect(deleted.sort()).toEqual(["files/a/one.png", "files/c/three.png"]);
  });

  it("deletes nothing when the user has no files", async () => {
    const { bucket, deleted } = fakeBucket([
      [{ key: "files/b/two.png", uploadedBy: "user-2" }],
    ]);

    const count = await purgeUserFiles(bucket, "user-1");

    expect(count).toBe(0);
    expect(deleted).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" npx vitest run src/scheduled/purge-deleted-accounts.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

`workers/api/src/scheduled/purge-deleted-accounts.ts`:

```ts
/**
 * Daily sweep: permanently erase accounts whose 14-day deletion window has
 * elapsed (user.deletion_requested_at set by DELETE /account).
 *
 * Per user, in order:
 *   1. Remove every connection via the connector's removeAuth callback
 *      (clears stored auth tokens, channel access, connection rows) —
 *      same path as in-app disconnect and plan-downgrade trimming.
 *   2. Archive remaining twist instances via archiveAndDeleteTwist (runs
 *      deactivate callbacks, archives links/threads), then delete any
 *      Unipile-hosted accounts — same path as in-app uninstall.
 *   3. Delete the user's uploaded files from R2 (matched on the
 *      uploadedBy custom metadata set by POST /files).
 *   4. Delete the Clerk user (idempotent if already gone).
 *   5. Delete the DB user row — FK cascades erase all remaining data and
 *      make the sweep terminal/idempotent.
 *
 * Steps 1-4 are best-effort (logged + captured); step 5 always runs so a
 * partial failure can't leave the account half-alive past the window.
 */
import { createClerkClient } from "@clerk/backend";
import { PostHog } from "posthog-node";
import type { Kysely } from "kysely";

import { createLogger } from "@plotday/worker-util";

import { sql, withDb, type DB } from "../db";
import type { Bindings } from "../env";
import { twistFactory } from "../twist/factory";
import {
  archiveAndDeleteTwist,
  removeIntegrationAccount,
} from "../twist/management";
import { deleteHostedAccountsForInstance } from "../twist/tools/unipile/account-cleanup";
import { BUILTIN_TWIST_PACKAGE_ID } from "../utils/limits";

const PURGE_AFTER = "14 days";
const MAX_USERS_PER_RUN = 25;

export type PurgeCandidate = {
  id: string;
  clerk_id: string | null;
  email: string;
};

export async function findUsersToPurge(
  db: Kysely<DB>
): Promise<PurgeCandidate[]> {
  return await db
    .selectFrom("user")
    .select(["id", "clerk_id", "email"])
    .where("deletion_requested_at", "is not", null)
    .where(
      "deletion_requested_at",
      "<",
      sql<string>`now() - interval '${sql.raw(PURGE_AFTER)}'`
    )
    .orderBy("deletion_requested_at", "asc")
    .limit(MAX_USERS_PER_RUN)
    .execute();
}

/** Minimal structural slice of R2Bucket used here (keeps tests dependency-free). */
export type FileBucket = {
  list(options: {
    prefix: string;
    cursor?: string;
    include: ["customMetadata"];
  }): Promise<
    | {
        objects: { key: string; customMetadata?: Record<string, string> }[];
        truncated: true;
        cursor: string;
      }
    | {
        objects: { key: string; customMetadata?: Record<string, string> }[];
        truncated: false;
      }
  >;
  delete(keys: string | string[]): Promise<void>;
};

export async function purgeUserFiles(
  bucket: FileBucket,
  userId: string
): Promise<number> {
  let cursor: string | undefined;
  let deleted = 0;
  do {
    const page = await bucket.list({
      prefix: "files/",
      cursor,
      include: ["customMetadata"],
    });
    const keys = page.objects
      .filter((o) => o.customMetadata?.uploadedBy === userId)
      .map((o) => o.key);
    if (keys.length > 0) {
      await bucket.delete(keys);
      deleted += keys.length;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}

export async function purgeDeletedAccounts(
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const logger = createLogger({ operation: "purgeDeletedAccounts" });
  const postHog = new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
  });

  try {
    await withDb(env, async (db) => {
      const users = await findUsersToPurge(db);
      if (users.length === 0) return;
      logger.info("Purging deleted accounts", { count: users.length });

      for (const user of users) {
        await purgeUser(env, ctx, db, user, logger, postHog);
      }
    });
  } finally {
    ctx.waitUntil(postHog.shutdown());
  }
}

async function purgeUser(
  env: Bindings,
  ctx: ExecutionContext,
  db: Kysely<DB>,
  user: PurgeCandidate,
  logger: ReturnType<typeof createLogger>,
  postHog: PostHog
): Promise<void> {
  const capture = (error: Error, step: string) => {
    logger.error(`Account purge step failed: ${step}`, error, {
      user_id: user.id,
    });
    postHog.captureException(error, undefined, {
      operation: "purgeDeletedAccounts",
      step,
      user_id: user.id,
    });
  };

  const factory = twistFactory({ env, ctx, db });

  // 1. Connections → connector removeAuth (clears stored tokens + channels).
  const connections = await db
    .selectFrom("twist_instance_connection as tic")
    .innerJoin("twist_instance as ti", "ti.id", "tic.twist_instance_id")
    .select(["tic.twist_instance_id", "tic.provider", "tic.actor_id"])
    .where("tic.user_id", "=", user.id)
    .where("ti.archived_at", "is", null)
    .execute();
  for (const row of connections) {
    try {
      await removeIntegrationAccount({
        db,
        env,
        twistFactory: factory,
        twistInstanceId: row.twist_instance_id,
        provider: row.provider,
        actorId: row.actor_id,
      });
    } catch (error) {
      capture(error as Error, "removeIntegrationAccount");
    }
  }

  // 2. Remaining twist instances → uninstall flow (skip the built-in Plot
  // twist, which archiveAndDeleteTwist refuses; its rows cascade in step 5).
  const instances = await db
    .selectFrom("twist_instance as ti")
    .innerJoin("twist as t", "t.id", "ti.twist_id")
    .select(["ti.id", "t.is_source"])
    .where("ti.owner_id", "=", user.id)
    .where("ti.archived_at", "is", null)
    .where("t.twist_package_id", "!=", BUILTIN_TWIST_PACKAGE_ID)
    .execute();
  for (const inst of instances) {
    try {
      await archiveAndDeleteTwist(db, inst.id, { twistFactory: factory });
      if (inst.is_source) {
        await deleteHostedAccountsForInstance(env, db, inst.id);
      }
    } catch (error) {
      capture(error as Error, "archiveAndDeleteTwist");
    }
  }

  // 3. Uploaded files in R2.
  try {
    const removed = await purgeUserFiles(
      env.FILES_BUCKET as unknown as FileBucket,
      user.id
    );
    if (removed > 0) {
      logger.info("Purged user files", { user_id: user.id, files: removed });
    }
  } catch (error) {
    capture(error as Error, "purgeUserFiles");
  }

  // 4. Clerk user (the user.deleted webhook may race us; both paths are
  // idempotent deletes by id).
  if (user.clerk_id) {
    try {
      const clerk = createClerkClient({ secretKey: env.CLERK_SECRET_KEY });
      await clerk.users.deleteUser(user.clerk_id);
    } catch (error) {
      const status = (error as { status?: number }).status;
      if (status !== 404) {
        capture(error as Error, "clerkDeleteUser");
      }
    }
  }

  // 5. DB row — cascades all remaining user data and ends eligibility.
  await db.deleteFrom("user").where("id", "=", user.id).execute();

  logger.info("Account permanently purged", { user_id: user.id });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" npx vitest run src/scheduled/purge-deleted-accounts.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/scheduled/purge-deleted-accounts.ts workers/api/src/scheduled/purge-deleted-accounts.test.ts
git commit -m "feat(api): automated permanent purge of deleted accounts

Daily sweep erases accounts 14+ days after deletion was requested:
connections via connector removeAuth (tokens cleared), twists via the
uninstall flow incl. Unipile hosted accounts, R2 files by uploadedBy
metadata, the Clerk user, then the DB row (cascades). Best-effort steps
log + captureException; the final row delete keeps the sweep idempotent.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Wire the purge into the cron

**Files:**
- Modify: `workers/api/src/index.ts` (imports ~line 60; scheduled handler — insert before the hour-5 `refreshAllChannels` block ~line 403)

- [ ] **Step 1: Add the import**

With the other scheduled imports (after line 60):

```ts
import { purgeDeletedAccounts } from "./scheduled/purge-deleted-accounts";
```

- [ ] **Step 2: Add the daily gate**

Following the existing daily-gate pattern (cron fires every 5 min; gate to one
window). Insert before the `getUTCHours() === 5` refreshAllChannels block:

```ts
  // Daily (06:00-06:04 UTC): permanently purge accounts whose 14-day
  // deletion window has elapsed — connections (stored tokens), twists,
  // uploaded files, the Clerk user, then the DB row (cascades).
  if (scheduledTime.getUTCHours() === 6 && scheduledMinutes < 5) {
    try {
      await purgeDeletedAccounts(env, _ctx);
    } catch (error) {
      logger.error("Error in account purge sweep", error as Error);
    }
  }
```

- [ ] **Step 3: Typecheck + full suite**

Run: `cd workers/api && pnpm lint && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm test`
Expected: lint clean; tests match baseline + new passing tests.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/index.ts
git commit -m "feat(api): schedule daily account purge sweep at 06:00 UTC

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: The /security page

**Files:**
- Create: `apps/site/app/routes/security.tsx`
- Modify: `apps/site/app/routes.ts` (after the `privacy` route line)
- Modify: `apps/site/app/components/public-layout.tsx` (footer links, after Privacy Policy ~line 111)

- [ ] **Step 1: Register the route**

In `apps/site/app/routes.ts`, after `route("privacy", "routes/privacy.tsx"),`:

```ts
    route("security", "routes/security.tsx"),
```

- [ ] **Step 2: Create the page**

`apps/site/app/routes/security.tsx` — complete file:

```tsx
import { Container, Title, TypographyStylesProvider } from "@mantine/core";

export default function Security() {
  return (
    <Container mt="lg">
      <Title order={1} mb="lg">
        Data &amp; Security
      </Title>
      <p>
        <em>Last updated: June 10, 2026</em>
      </p>
      <TypographyStylesProvider p={0}>
        <p>
          Plot connects to the tools where your work happens — your email,
          your calendar, your team chat. That means we hold data worth
          protecting, and we treat that as part of the product. This page
          explains where your data lives, who can see it, and how we keep it
          safe.
        </p>

        <h2 id="where-your-data-lives">Where your data lives</h2>
        <p>
          Plot is local-first. The app keeps a copy of your data on your
          device, so it works offline and stays fast. That copy is protected
          by your device&apos;s own storage encryption.
        </p>
        <p>
          Your data syncs to our servers for backup, for your other devices,
          and for sharing with the people you choose. Our database runs on
          Google Cloud in Toronto, Canada, and is backed up automatically
          every day. Our API runs on Cloudflare&apos;s network.
        </p>

        <h2 id="encryption">Encryption</h2>
        <p>
          Everything moving between your device and our servers is encrypted
          in transit with TLS. Everything stored on our servers is encrypted
          at rest by our infrastructure providers.
        </p>
        <p>
          The most sensitive pieces — the tokens that link your connected
          accounts, and any AI keys you bring — are encrypted a second time
          at the application level with AES-256, using keys we manage.
        </p>

        <h2 id="your-connected-accounts">Your connected accounts</h2>
        <p>
          Connections use OAuth: you sign in with the provider directly, and
          Plot receives a scoped token — never your password. Each connection
          asks only for the access its features need, and you can disconnect
          at any time. Disconnecting removes the stored tokens.
        </p>
        <p>
          Connectors run inside a sandboxed runtime with access only to the
          capabilities they declare.
        </p>
        <p>
          Plot&apos;s use of information received from Google Workspace APIs
          adheres to the{" "}
          <a href="https://developers.google.com/terms/api-services-user-data-policy">
            Google User Data Policy
          </a>
          , including the Limited Use requirements. Because Plot can access
          Gmail, we also pass an annual independent security assessment
          (CASA) that Google requires for that access.
        </p>

        <h2 id="ai">AI</h2>
        <p>
          AI in Plot does things you can see — summarize a thread, suggest
          where something belongs. We send only what a feature needs to our
          AI providers (Anthropic, Google, and OpenAI), under agreements that
          prohibit them from training on your data or keeping it beyond the
          response. We never use your data to train models either. You can
          turn off AI processing entirely in your account settings.
        </p>

        <h2 id="who-can-see-your-work">Who can see your work</h2>
        <p>
          Your threads are visible to you and the people you&apos;ve shared
          them with — directly, through a group, or through your team. Drafts
          stay private until you send them. These rules are enforced in the
          database itself, on every query, not just in the app.
        </p>
        <p>
          People at Plot don&apos;t read your data. The narrow exceptions —
          debugging with your consent, investigating abuse, legal
          requirements — are spelled out in our{" "}
          <a href="/privacy">privacy policy</a>.
        </p>

        <h2 id="deleting-your-data">Deleting your data</h2>
        <p>
          You can delete your account from the app at any time. We hold your
          data for 14 days in case you change your mind, then everything is
          erased automatically and permanently — your content, your
          connection tokens, and your files.
        </p>

        <h2 id="payments">Payments</h2>
        <p>
          Payments are handled by Stripe. Your card details go to Stripe
          directly and never touch our servers.
        </p>

        <h2 id="services-we-rely-on">The services we rely on</h2>
        <p>Plot runs on a small set of providers, each doing one job:</p>
        <ul>
          <li>
            <strong>Cloudflare</strong> — API hosting, networking, and file
            storage
          </li>
          <li>
            <strong>Google Cloud</strong> — database hosting (Toronto,
            Canada)
          </li>
          <li>
            <strong>Clerk</strong> — sign-in and authentication
          </li>
          <li>
            <strong>Stripe</strong> — payments
          </li>
          <li>
            <strong>Anthropic, Google, and OpenAI</strong> — AI features
            (optional; never used for training)
          </li>
          <li>
            <strong>Unipile</strong> — powers the LinkedIn, WhatsApp, and
            Instagram connections
          </li>
          <li>
            <strong>PostHog</strong> — product analytics and error tracking
          </li>
          <li>
            <strong>Resend</strong> — email notifications
          </li>
          <li>
            <strong>Firebase and Apple Push</strong> — notifications to your
            devices
          </li>
        </ul>
        <p>
          That&apos;s the full list. We don&apos;t sell your data, and we
          don&apos;t show ads.
        </p>

        <h2 id="report-a-security-issue">If you find a security issue</h2>
        <p>
          Email <a href="mailto:security@plot.day">security@plot.day</a> — it
          reaches us directly, and we respond quickly. We also publish{" "}
          <a href="/.well-known/security.txt">security.txt</a> for automated
          discovery.
        </p>

        <h2 id="where-we-are">Where we are</h2>
        <p>
          We&apos;re a small team, and we don&apos;t have a SOC 2 report yet.
          What we do have: the controls on this page, an independent security
          assessment every year, and an architecture that keeps your data on
          your device first. If you&apos;re evaluating Plot for your business
          and need more than this page, write to{" "}
          <a href="mailto:security@plot.day">security@plot.day</a> — a person
          will answer.
        </p>
      </TypographyStylesProvider>
    </Container>
  );
}
```

- [ ] **Step 3: Add the footer link**

In `apps/site/app/components/public-layout.tsx`, after the Privacy Policy
anchor:

```tsx
          <Anchor component={Link} to="/security">
            Security
          </Anchor>
```

- [ ] **Step 4: Lint + build**

Run: `cd apps/site && pnpm lint && pnpm build`
Expected: clean lint, successful build.

- [ ] **Step 5: Commit**

```bash
git add apps/site/app/routes/security.tsx apps/site/app/routes.ts apps/site/app/components/public-layout.tsx
git commit -m "feat(site): Data & Security page at /security

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: docs/updates.md

**Files:**
- Modify: `docs/updates.md` (very top, above the existing first bullet)

- [ ] **Step 1: Add the bullet**

```markdown
- Plot now has a public Data & Security page at [plot.day/security](https://plot.day/security) explaining in plain language where your data lives, who can see it, and how it's protected. Alongside it, deleting your account now erases everything automatically and permanently after the 14-day recovery window, and the tokens for your connected accounts get an extra layer of encryption on our servers.
```

- [ ] **Step 2: Commit**

```bash
git add docs/updates.md
git commit -m "docs: announce the Data & Security page

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Final verification

- [ ] **Step 1: Full lint + test sweep**

```bash
cd workers/api && pnpm lint && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm test
cd ../../apps/site && pnpm lint
cd ../.. && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm --filter @plotday/db run lint
DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54331/postgres" pnpm diff-schema-migrations
```

Expected: all clean except the known pre-existing thread-unread failure.

- [ ] **Step 2: Visual check of the page**

```bash
cd apps/site && pnpm dev
```

Open http://localhost:<port>/security — verify heading hierarchy, footer link,
and http://localhost:<port>/.well-known/security.txt serves the file. Stop the
server after.

- [ ] **Step 3: Run /finalize** (lint, backwards compat, error capture, docs,
  public submodule check — no submodule changes expected in this work).

---

## Go-live checklist (Kris, after merge)

1. Create the 1Password field `op://Production/Database/Encryption Keys/token`
   (64-char hex, e.g. `openssl rand -hex 32`) and refresh worker secrets so
   `TOKEN_ENCRYPTION_KEY` reaches workers/api.
2. Enable Dependabot alerts + security updates in GitHub repo settings.
3. Deploy includes migration `user_deletion_requested_at` (standard expand flow).
4. security@plot.day alias is live (done).
