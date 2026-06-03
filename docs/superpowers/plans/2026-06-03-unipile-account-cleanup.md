# Unipile Account Cleanup & Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop paying for orphaned Unipile accounts by deleting the upstream Unipile account whenever a Plot connection is torn down, and by sweeping same-identity orphans whenever a LinkedIn account is (re)connected — including after a dev DB reset.

**Architecture:** Three best-effort cleanup paths, all routed through one helper module so a failure never blocks a teardown or an auth completion. (A) per-account removal (`Integrations.removeAuth`) deletes the hosted account; (B) connect completion (`authBridge`) sweeps other Unipile accounts for the same LinkedIn identity that no live Plot connection references; (C) whole-connector removal routes (`twists.ts`) delete the instance's hosted accounts in the background. The Unipile `account_id` equals the auth token's `access_token` and the `channel.channel_id`.

**Tech Stack:** TypeScript, Cloudflare Workers, Hono, Kysely, Vitest. All changes are local-only in `workers/api`. No schema changes, no Twister/SDK changes, no public submodule.

---

## Context the engineer needs

- **Unipile client:** `workers/api/src/twist/tools/unipile/client.ts` is the only place that knows Unipile's HTTP shape. It already has `getAccount(id)` and `deleteAccount(id)` (DELETE returns 204; non-2xx throws `UnipileApiError` with `.status`). You will add `listAccounts()`.
- **Account id ≡ token ≡ channel id:** For hosted-auth providers (LinkedIn today; WhatsApp/Instagram later) the Unipile `account_id` is stored as `StoredTokenData.access_token` in the connector's DO store under `auth_token:<provider>:<actorId>`, and mirrored into the relational `channel` table as `channel.channel_id`. (`provider.ts` comment: "The `accountId` doubles as the access_token because every Unipile call needs it.")
- **Hosted detection:** `PROVIDER_CONFIGS[provider]?.authMode === "hosted"` (from `workers/api/src/provider.ts`). `PROVIDER_CONFIGS` is already imported in `integrations.ts`.
- **LinkedIn identity:** the LinkedIn member id. On a Unipile account it is `connection_params.im.id`. At connect time `authBridge` already computes it into the local `userId` (from `profile.provider_id`, with fallbacks).
- **Teardown paths today (all leak):**
  - `Integrations.removeAuth(provider, actorId)` — clears the token at `integrations.ts:2930`; never deletes the Unipile account.
  - `DELETE /twist/:id` → `deleteTwist(trx, id)` and `DELETE /twist/:id/archive-activities` → `archiveAndDeleteTwist(db, id)` — both called **without** the `deactivate` factory, so `deactivate()`/`preDeactivate` do **not** run. They only soft-archive `twist_instance` (`archived_at`) and set `channel.enabled = false`; `channel` rows and DO-store tokens survive.
- **`waitUntil` rule (CLAUDE.md):** never use `c.var.db` inside `c.executionCtx.waitUntil(...)` — open a fresh `createDb(c.env)` inside the task and `destroy()` it in `finally`. Canonical example: `workers/api/src/app/sync/links.ts:192`.
- **Tests:** unit tests live next to source (e.g. `unipile/client.test.ts`) and run via `pnpm --filter @plotday/api test` (vitest, node pool; the `__tests__/` dir is the separate workers-pool integration config — do NOT put these there). Mock Unipile HTTP with `vi.spyOn(globalThis, "fetch")` as in `client.test.ts`.
- **Lint gate (memory):** `pnpm --filter @plotday/api lint` runs `tsc`; `main` already has 2 pre-existing `error TS` lines. The gate is "no NEW `error TS`", not exit 0.
- **Error capture (CLAUDE.md):** unexpected catch blocks call `captureException`. Twist/connector code has no PostHog — but these files are API-worker code, so `tracker.captureException` applies where a tracker is available.

## File structure

- `workers/api/src/twist/tools/unipile/types.ts` — add `UnipileAccountList`.
- `workers/api/src/twist/tools/unipile/client.ts` — add `listAccounts()`.
- `workers/api/src/twist/tools/unipile/account-cleanup.ts` — **NEW.** All cleanup logic: `deleteUnipileAccount`, `selectOrphanAccountIds` (pure), `sweepOrphanAccountsForIdentity`, `deleteHostedAccountsForInstance`.
- `workers/api/src/twist/tools/unipile/account-cleanup.test.ts` — **NEW.** Unit tests for the pure selector + `deleteUnipileAccount`.
- `workers/api/src/twist/tools/unipile/client.test.ts` — add `listAccounts` pagination test.
- `workers/api/src/twist/tools/integrations.ts` — `removeAuth` deletes the hosted account (Flow A).
- `workers/api/src/app/authBridge.ts` — background connect-time orphan sweep (Flow B).
- `workers/api/src/app/twists.ts` — background hosted-account cleanup on removal routes (Flow C).

---

## Task 1: `listAccounts()` on the Unipile client

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/types.ts`
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Test: `workers/api/src/twist/tools/unipile/client.test.ts`

- [ ] **Step 1: Add the list type**

In `types.ts`, directly after the `UnipileAccount` type (ends at the line with `name?: string;` then `};`), add:

```typescript
export type UnipileAccountList = {
  object: "AccountList";
  items: UnipileAccount[];
  cursor: string | null;
};
```

- [ ] **Step 2: Write the failing test**

Append to the `describe("UnipileClient", ...)` block in `client.test.ts`:

```typescript
  it("listAccounts walks pages and concatenates items", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          object: "AccountList",
          items: [{ object: "Account", id: "acct-1", type: "LINKEDIN", created_at: "2026-01-01T00:00:00Z", sources: [] }],
          cursor: "page-2",
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      )
    );
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          object: "AccountList",
          items: [{ object: "Account", id: "acct-2", type: "LINKEDIN", created_at: "2026-01-02T00:00:00Z", sources: [] }],
          cursor: null,
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      )
    );

    const client = new UnipileClient(env);
    const accounts = await client.listAccounts();

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(String(fetchSpy.mock.calls[0]![0])).toBe(
      "https://api7.unipile.com:13441/api/v1/accounts"
    );
    expect(String(fetchSpy.mock.calls[1]![0])).toBe(
      "https://api7.unipile.com:13441/api/v1/accounts?cursor=page-2"
    );
    expect(accounts.map((a) => a.id)).toEqual(["acct-1", "acct-2"]);
  });
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test -- client.test.ts`
Expected: FAIL — `client.listAccounts is not a function`.

- [ ] **Step 4: Implement `listAccounts`**

In `client.ts`, add the import to the existing `./types` import list: add `UnipileAccount,` and `UnipileAccountList,` (keep alphabetical-ish ordering with the others). Then, inside the `// ---------- Account lifecycle ----------` section (right after `deleteAccount`), add:

```typescript
  /**
   * List every account in the Unipile workspace. The workspace holds at most a
   * handful of accounts, but the endpoint is cursor-paginated so we walk all
   * pages. Used by account-cleanup to find orphaned accounts to delete.
   */
  async listAccounts(): Promise<UnipileAccount[]> {
    const out: UnipileAccount[] = [];
    let cursor: string | null = null;
    do {
      const page: UnipileAccountList = await this.get<UnipileAccountList>(
        "/accounts",
        cursor ? { cursor } : undefined
      );
      out.push(...page.items);
      cursor = page.cursor ?? null;
    } while (cursor);
    return out;
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api test -- client.test.ts`
Expected: PASS (all tests in the file).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/twist/tools/unipile/types.ts workers/api/src/twist/tools/unipile/client.ts workers/api/src/twist/tools/unipile/client.test.ts
git commit -m "feat(unipile): add listAccounts() to the client"
```

---

## Task 2: `deleteUnipileAccount` best-effort helper

**Files:**
- Create: `workers/api/src/twist/tools/unipile/account-cleanup.ts`
- Test: `workers/api/src/twist/tools/unipile/account-cleanup.test.ts`

- [ ] **Step 1: Write the failing test**

Create `account-cleanup.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Bindings } from "../../../env";
import { deleteUnipileAccount } from "./account-cleanup";

const env = {
  UNIPILE_API_KEY: "test-key",
  UNIPILE_DSN: "api7.unipile.com:13441",
  UNIPILE_WEBHOOK_SECRET: "test-secret",
} as unknown as Bindings;

describe("deleteUnipileAccount", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch");
  });
  afterEach(() => {
    fetchSpy.mockRestore();
  });

  it("DELETEs the account on the Unipile API", async () => {
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 204 }));
    await deleteUnipileAccount(env, "acct-1");
    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(String(url)).toBe(
      "https://api7.unipile.com:13441/api/v1/accounts/acct-1"
    );
    expect(init?.method).toBe("DELETE");
  });

  it("swallows a 404 (account already gone)", async () => {
    fetchSpy.mockResolvedValueOnce(new Response('{"status":404}', { status: 404 }));
    await expect(deleteUnipileAccount(env, "gone")).resolves.toBeUndefined();
  });

  it("never throws on an unexpected error and reports it to the tracker", async () => {
    fetchSpy.mockResolvedValueOnce(new Response('{"status":500}', { status: 500 }));
    const tracker = { captureException: vi.fn() };
    await expect(
      deleteUnipileAccount(env, "boom", { tracker })
    ).resolves.toBeUndefined();
    expect(tracker.captureException).toHaveBeenCalledOnce();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test -- account-cleanup.test.ts`
Expected: FAIL — cannot find module `./account-cleanup`.

- [ ] **Step 3: Implement the helper module**

Create `account-cleanup.ts`:

```typescript
import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../../../env";
import { UnipileApiError, UnipileClient } from "./client";

/** Minimal tracker shape so callers can pass `c.var.tracker` without coupling. */
type Tracker = { captureException: (error: unknown) => void };

/**
 * Delete one Unipile account, best-effort. Cleanup must never block a teardown
 * or an auth completion, so this NEVER throws: a 404 means the account is
 * already gone (success); any other failure is logged and reported.
 */
export async function deleteUnipileAccount(
  env: Bindings,
  accountId: string,
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    account_id: accountId,
  });
  try {
    await new UnipileClient(env).deleteAccount(accountId);
    logger.info("Deleted Unipile account");
  } catch (error) {
    if (error instanceof UnipileApiError && error.status === 404) {
      logger.info("Unipile account already gone (404)");
      return;
    }
    logger.error("Failed to delete Unipile account", error as Error);
    opts?.tracker?.captureException(error);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api test -- account-cleanup.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile/account-cleanup.ts workers/api/src/twist/tools/unipile/account-cleanup.test.ts
git commit -m "feat(unipile): best-effort deleteUnipileAccount helper"
```

---

## Task 3: `selectOrphanAccountIds` pure selector

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/account-cleanup.ts`
- Test: `workers/api/src/twist/tools/unipile/account-cleanup.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `account-cleanup.test.ts` (add `selectOrphanAccountIds` to the import on line 3):

```typescript
describe("selectOrphanAccountIds", () => {
  const accounts = [
    { id: "new", identity: "member-A" },
    { id: "old-1", identity: "member-A" },
    { id: "old-2", identity: "member-A" },
    { id: "other-user", identity: "member-B" },
    { id: "unknown", identity: null },
  ];

  it("selects same-identity accounts, excluding the new one", () => {
    const result = selectOrphanAccountIds(accounts, "new", "member-A", new Set());
    expect(result.sort()).toEqual(["old-1", "old-2"]);
  });

  it("never selects accounts for a different identity", () => {
    const result = selectOrphanAccountIds(accounts, "new", "member-A", new Set());
    expect(result).not.toContain("other-user");
    expect(result).not.toContain("unknown");
  });

  it("skips accounts still referenced by a live connection", () => {
    const result = selectOrphanAccountIds(
      accounts,
      "new",
      "member-A",
      new Set(["old-1"])
    );
    expect(result).toEqual(["old-2"]);
  });

  it("returns nothing when the identity is unknown", () => {
    expect(selectOrphanAccountIds(accounts, "new", "", new Set())).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api test -- account-cleanup.test.ts`
Expected: FAIL — `selectOrphanAccountIds is not exported`.

- [ ] **Step 3: Implement the pure selector**

Append to `account-cleanup.ts`:

```typescript
/**
 * Pure decision logic for the connect-time orphan sweep. Given every Unipile
 * account (each reduced to `{ id, identity }`), the account just connected, its
 * LinkedIn identity, and the set of account ids a live Plot connection still
 * references, return the ids to delete.
 *
 * An account is an orphan when it belongs to the SAME LinkedIn identity, is not
 * the account just connected, and is not referenced by any live connection
 * (the reference guard protects the rare case of two Plot users on one LinkedIn
 * login). A blank `identityId` selects nothing.
 */
export function selectOrphanAccountIds(
  accounts: Array<{ id: string; identity: string | null }>,
  newAccountId: string,
  identityId: string,
  referencedIds: Set<string>
): string[] {
  if (!identityId) return [];
  return accounts
    .filter(
      (a) =>
        a.id !== newAccountId &&
        a.identity === identityId &&
        !referencedIds.has(a.id)
    )
    .map((a) => a.id);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api test -- account-cleanup.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile/account-cleanup.ts workers/api/src/twist/tools/unipile/account-cleanup.test.ts
git commit -m "feat(unipile): pure selectOrphanAccountIds for connect-time sweep"
```

---

## Task 4: `sweepOrphanAccountsForIdentity` wiring (Flow B core)

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/account-cleanup.ts`

No new test — this is thin wiring over `listAccounts` (Task 1), `selectOrphanAccountIds` (Task 3), `deleteUnipileAccount` (Task 2), and one DB query. Verified by typecheck + the Flow-B manual check in Task 9.

- [ ] **Step 1: Add imports**

At the top of `account-cleanup.ts` add:

```typescript
import type { Kysely } from "kysely";

import type { DB } from "../../../db-types";
import type { UnipileAccount } from "./types";
```

- [ ] **Step 2: Implement the sweep + its two private helpers**

Append to `account-cleanup.ts`:

```typescript
/**
 * Resolve a Unipile account's LinkedIn identity (member id). It is usually on
 * the list payload as `connection_params.im.id`; if a leaner list shape omits
 * it, fall back to a per-account GET (cheap — workspaces hold only a handful of
 * accounts).
 */
async function accountIdentity(
  client: UnipileClient,
  account: UnipileAccount
): Promise<string | null> {
  const fromList = account.connection_params?.im?.id ?? null;
  if (fromList) return fromList;
  try {
    const full = await client.getAccount(account.id);
    return full.connection_params?.im?.id ?? null;
  } catch {
    return null;
  }
}

/**
 * Of the given Unipile account ids, which are still referenced by a live Plot
 * connection — an ENABLED `channel` row under a NON-archived `twist_instance`
 * (channel_id == account_id for hosted connectors).
 */
async function referencedAccountIds(
  db: Kysely<DB>,
  accountIds: string[]
): Promise<Set<string>> {
  if (accountIds.length === 0) return new Set();
  const rows = await db
    .selectFrom("channel")
    .innerJoin("twist_instance", "twist_instance.id", "channel.twist_instance_id")
    .select("channel.channel_id")
    .where("channel.channel_id", "in", accountIds)
    .where("channel.enabled", "=", true)
    .where("twist_instance.archived_at", "is", null)
    .execute();
  return new Set(rows.map((r) => r.channel_id));
}

/**
 * Connect-time orphan sweep (Flow B). After a hosted account finishes auth,
 * delete every OTHER Unipile account for the same LinkedIn identity that no
 * live Plot connection references. Best-effort: never throws.
 */
export async function sweepOrphanAccountsForIdentity(
  env: Bindings,
  db: Kysely<DB>,
  params: { newAccountId: string; identityId: string },
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    new_account_id: params.newAccountId,
  });
  if (!params.identityId || params.identityId === params.newAccountId) return;

  let accounts: UnipileAccount[];
  try {
    accounts = await new UnipileClient(env).listAccounts();
  } catch (error) {
    logger.error("Orphan sweep: listAccounts failed", error as Error);
    opts?.tracker?.captureException(error);
    return;
  }

  const client = new UnipileClient(env);
  const reduced = await Promise.all(
    accounts.map(async (a) => ({ id: a.id, identity: await accountIdentity(client, a) }))
  );

  const sameIdentity = reduced
    .filter((a) => a.id !== params.newAccountId && a.identity === params.identityId)
    .map((a) => a.id);
  const referenced = await referencedAccountIds(db, sameIdentity);
  const toDelete = selectOrphanAccountIds(
    reduced,
    params.newAccountId,
    params.identityId,
    referenced
  );

  if (toDelete.length === 0) return;
  logger.info("Orphan sweep: deleting stale Unipile accounts", {
    count: toDelete.length,
  });
  for (const id of toDelete) {
    await deleteUnipileAccount(env, id, opts);
  }
}
```

- [ ] **Step 2: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines beyond the 2 pre-existing ones.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/tools/unipile/account-cleanup.ts
git commit -m "feat(unipile): sweepOrphanAccountsForIdentity (connect-time orphan cleanup)"
```

---

## Task 5: `deleteHostedAccountsForInstance` wiring (Flow C core)

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/account-cleanup.ts`

No new test — thin wiring over a KV read + one DB query + `deleteUnipileAccount`. Verified by typecheck + the Flow-C manual check in Task 9.

- [ ] **Step 1: Add the provider-config import**

At the top of `account-cleanup.ts` add:

```typescript
import { PROVIDER_CONFIGS } from "../../../provider";
```

- [ ] **Step 2: Implement the instance cleanup**

Append to `account-cleanup.ts`:

```typescript
/**
 * Delete every hosted (Unipile) account belonging to a removed connector
 * instance (Flow C). For hosted connectors the `channel.channel_id` IS the
 * Unipile account id. Runs after the instance is soft-archived, so the channel
 * rows and KV config still exist. Best-effort: never throws.
 */
export async function deleteHostedAccountsForInstance(
  env: Bindings,
  db: Kysely<DB>,
  twistInstanceId: string,
  opts?: { tracker?: Tracker }
): Promise<void> {
  const logger = createLogger({
    component: "unipile-account-cleanup",
    twist_instance_id: twistInstanceId,
  });

  const info = await db
    .selectFrom("twist_instance")
    .innerJoin("twist", "twist.id", "twist_instance.twist_id")
    .select(["twist.twist_package_id as twistPackageId", "twist.version"])
    .where("twist_instance.id", "=", twistInstanceId)
    .executeTakeFirst();
  if (!info?.twistPackageId || !info.version) return;

  const raw = await env.TWIST_CONFIG.get(`${info.twistPackageId}:${info.version}`);
  if (!raw) return;
  let providers: Array<{ provider: string }> = [];
  try {
    providers = JSON.parse(raw).providers ?? [];
  } catch {
    return;
  }
  const hasHosted = providers.some(
    (p) =>
      PROVIDER_CONFIGS[p.provider as keyof typeof PROVIDER_CONFIGS]?.authMode ===
      "hosted"
  );
  if (!hasHosted) return;

  const channels = await db
    .selectFrom("channel")
    .select("channel_id")
    .where("twist_instance_id", "=", twistInstanceId)
    .execute();
  if (channels.length === 0) return;

  logger.info("Connector removed: deleting hosted Unipile accounts", {
    count: channels.length,
  });
  for (const ch of channels) {
    await deleteUnipileAccount(env, ch.channel_id, opts);
  }
}
```

- [ ] **Step 3: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines. (If `info.version` is typed `string | null`, the `!info.version` guard narrows it; if `twist.version` does not exist as a column, instead select `twist_instance` + `twist` columns matching `resolveTwistInfo` in `twist-integrations.ts` which selects `twist.version` — confirm the column name there.)

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/tools/unipile/account-cleanup.ts
git commit -m "feat(unipile): deleteHostedAccountsForInstance for connector removal"
```

---

## Task 6: Flow A — delete the hosted account in `removeAuth`

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (method `removeAuth`, ~lines 2864-2952)

- [ ] **Step 1: Add the import**

Near the existing `import { UnipileClient } from "./unipile/client";` line in `integrations.ts`, add:

```typescript
import { deleteUnipileAccount } from "./unipile/account-cleanup";
```

Also confirm `StoredTokenData` is imported in this file (it is used elsewhere in the file). If not, add it to the existing `../../provider` import.

- [ ] **Step 2: Capture the hosted account id before the token is cleared**

In `removeAuth`, immediately after the line `const tokenKey = \`auth_token:${provider}:${actorId}\`;` (the first line of the method), insert:

```typescript
    // For hosted-auth providers (LinkedIn, etc.) the token's access_token is
    // the Unipile account id. Capture it now so we can delete the upstream
    // account after the local token is cleared.
    let hostedAccountId: string | null = null;
    if (PROVIDER_CONFIGS[provider]?.authMode === "hosted") {
      const existing = await this.store.get<StoredTokenData>(tokenKey);
      hostedAccountId = existing?.access_token ?? null;
    }
```

- [ ] **Step 3: Delete the account after the token is cleared**

In `removeAuth`, find the cleanup tail (after `await this.store.clear(\`syncable_access:${provider}:${actorId}\`);`, just before the `// Return dispatch info...` comment / the `if (dispatches.length > 0)` block). Insert:

```typescript
    // Delete the upstream Unipile account, unless another live hosted token
    // still references it (channel reassignment). For personal hosted accounts
    // there is never another owner, so this deletes. Best-effort.
    if (hostedAccountId) {
      const stillReferenced = await this.hostedAccountStillReferenced(
        provider,
        hostedAccountId
      );
      if (!stillReferenced) {
        await deleteUnipileAccount(this.env, hostedAccountId);
      }
    }
```

- [ ] **Step 4: Add the `hostedAccountStillReferenced` private method**

Immediately after the `removeAuth` method's closing brace, add:

```typescript
  /**
   * True iff some OTHER stored auth token for this provider still points at the
   * given Unipile account id. removeAuth has already cleared the removed
   * actor's token, so a match here means a different actor still owns the
   * account (the channel-reassignment case) and we must not delete it upstream.
   */
  private async hostedAccountStillReferenced(
    provider: AuthProvider,
    accountId: string
  ): Promise<boolean> {
    const keys = await this.store.list(`auth_token:${provider}:`);
    for (const key of keys) {
      const token = await this.store.get<StoredTokenData>(key);
      if (token?.access_token === accountId) return true;
    }
    return false;
  }
```

- [ ] **Step 5: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines. (Confirm `this.env`, `this.store`, and the `AuthProvider` type are all in scope in this class — they are used throughout `removeAuth` and the file.)

- [ ] **Step 6: Run the unit suite (no regressions)**

Run: `pnpm --filter @plotday/api test -- account-cleanup.test.ts client.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "feat(integrations): delete Unipile account on removeAuth (hosted providers)"
```

---

## Task 7: Flow B — connect-time orphan sweep in `authBridge`

**Files:**
- Modify: `workers/api/src/app/authBridge.ts` (handler `GET /auth/hosted/success`)

- [ ] **Step 1: Add imports**

At the top of `authBridge.ts`, add:

```typescript
import { createDb } from "../db";
import { PROVIDER_CONFIGS } from "../provider";
import type { AuthProvider } from "../twist/tools/integrations";
import { sweepOrphanAccountsForIdentity } from "../twist/tools/unipile/account-cleanup";
```

(`createDb`'s exact module path is `../db` — confirm against `workers/api/src/app/sync/links.ts` which imports `createDb` from `../../db`.)

- [ ] **Step 2: Kick off the background sweep after onAuth succeeds**

In the `/auth/hosted/success` handler, the success path ends with cleaning up state keys then `return htmlBridgeResponse({ bridgeUri, state });`. Immediately BEFORE that final `return` (and after the `await Promise.all([...clear...])`), insert:

```typescript
  // Best-effort: a fresh connect for a LinkedIn identity means any OTHER
  // Unipile account for that same identity is a stale orphan (older connects,
  // or accounts stranded by a dev DB reset). Sweep them in the background so
  // the redirect isn't delayed. `userId` is the LinkedIn member id
  // (profile.provider_id) resolved above.
  if (
    provider &&
    PROVIDER_CONFIGS[provider as AuthProvider]?.authMode === "hosted"
  ) {
    const newAccountId = result.accountId;
    const identityId = userId;
    const env = c.env;
    const tracker = c.var.tracker;
    c.executionCtx.waitUntil(
      (async () => {
        const db = createDb(env);
        try {
          await sweepOrphanAccountsForIdentity(
            env,
            db,
            { newAccountId, identityId },
            { tracker }
          );
        } finally {
          await db.destroy();
        }
      })()
    );
  }
```

- [ ] **Step 3: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines. (`provider`, `userId`, and `result` are all locals already in scope in this handler. If `c.var.tracker` is typed `Tracker | undefined`, that matches `sweepOrphanAccountsForIdentity`'s optional `tracker`.)

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/app/authBridge.ts
git commit -m "feat(authBridge): sweep orphaned Unipile accounts on hosted connect"
```

---

## Task 8: Flow C — delete hosted accounts on the connector-removal routes

**Files:**
- Modify: `workers/api/src/app/twists.ts` (`DELETE /twist/:id` and `DELETE /twist/:id/archive-activities`)

- [ ] **Step 1: Add imports**

At the top of `twists.ts`, add:

```typescript
import { createDb } from "../db";
import { deleteHostedAccountsForInstance } from "../twist/tools/unipile/account-cleanup";
```

(If `createDb` is already imported in this file, skip the duplicate.)

- [ ] **Step 2: Add a small local helper near the top of the file (after imports)**

```typescript
/**
 * Fire-and-forget deletion of a removed connector's hosted (Unipile) accounts.
 * Runs after the instance is soft-archived; the channel rows and KV config
 * still exist. Uses a fresh DB connection because c.var.db is destroyed once
 * the response is sent.
 */
function cleanupHostedAccounts(
  c: { env: Bindings; executionCtx: ExecutionContext; var: { tracker?: { captureException: (e: unknown) => void } } },
  twistInstanceId: string
): void {
  const env = c.env;
  const tracker = c.var.tracker;
  c.executionCtx.waitUntil(
    (async () => {
      const db = createDb(env);
      try {
        await deleteHostedAccountsForInstance(env, db, twistInstanceId, { tracker });
      } finally {
        await db.destroy();
      }
    })()
  );
}
```

(Confirm `Bindings` is imported in `twists.ts` — it is used in the `Hono<{ Bindings: Bindings }>` generic. If `c.var.tracker` isn't on the typed context, loosen the param type to `any` for `c` or read `c.get("tracker")`; match however other handlers in this file access the tracker.)

- [ ] **Step 3: Call it from `DELETE /twist/:id`**

Change the handler body so cleanup fires after the transaction commits:

```typescript
twists.delete("/twist/:id", async (c) => {
  const twistId = c.req.param("id");
  const access = await checkTwistAccess(
    c.var.db,
    twistId,
    c.var.user.id,
    "write"
  );
  if (!access.ok) return c.json(notFoundResponse, 404);
  await c.var.db.transaction().execute(async (trx) => {
    await deleteTwist(trx, twistId);
  });
  cleanupHostedAccounts(c, twistId);
  return c.json({ success: true });
});
```

- [ ] **Step 4: Call it from `DELETE /twist/:id/archive-activities`**

In that handler, after `const result = await archiveAndDeleteTwist(c.var.db, twistId);` and before the `return c.json({ success: true });`, insert:

```typescript
  cleanupHostedAccounts(c, twistId);
```

- [ ] **Step 5: Typecheck**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/twists.ts
git commit -m "feat(twists): delete hosted Unipile accounts on connector removal"
```

---

## Task 9: Full verification + finalize

**Files:** none (verification only)

- [ ] **Step 1: Run the full API unit suite**

Run: `pnpm --filter @plotday/api test`
Expected: PASS (or only pre-existing unrelated failures — compare against `main` if anything looks off).

- [ ] **Step 2: Lint the package**

Run: `pnpm --filter @plotday/api lint`
Expected: no NEW `error TS` lines beyond the 2 pre-existing ones recorded in project memory.

- [ ] **Step 3: Flow B manual reasoning check**

Re-read `sweepOrphanAccountsForIdentity` against `authBridge`'s success path and confirm: `userId` is the LinkedIn member id (`profile.provider_id`) on the happy path; when `getOwnProfile` failed and `userId` fell back to `result.accountId`, `identityId === newAccountId` so the early-return makes the sweep a safe no-op.

- [ ] **Step 4: Flow C manual reasoning check**

Confirm `deleteHostedAccountsForInstance` reads `channel` rows that still exist after soft-archive (the removal routes set `archived_at` / `enabled=false` but do not hard-delete `twist_instance` or `channel`), and that the `twist.version` / `twist.twist_package_id` column names match `resolveTwistInfo` in `twist-integrations.ts`.

- [ ] **Step 5: Run `/finalize`**

Per project AGENTS.md, run the `/finalize` checklist (lint, backwards-compat, error capture, docs). Note: no user-facing UI change, so `docs/updates.md` likely needs no entry; this is a billing/safety fix. Confirm every new `catch` that handles an unexpected error reports via `captureException` (already wired through the `tracker` option).

- [ ] **Step 6: Final commit if `/finalize` produced changes**

```bash
git add -A
git commit -m "chore: finalize Unipile account cleanup"
```

---

## Self-review notes

- **Spec coverage:** Flow A → Task 6; Flow B → Tasks 1,3,4,7; Flow C → Tasks 1,5,8; shared `deleteUnipileAccount` → Task 2; `listAccounts` → Task 1; tests → Tasks 1-3 + Task 9. The spec's "delete on a plain channel disable" non-goal is respected (no change to `disableSync`).
- **Type consistency:** `deleteUnipileAccount(env, accountId, opts?)`, `selectOrphanAccountIds(accounts, newAccountId, identityId, referencedIds)`, `sweepOrphanAccountsForIdentity(env, db, {newAccountId, identityId}, opts?)`, and `deleteHostedAccountsForInstance(env, db, twistInstanceId, opts?)` are used identically in every caller. The `{ tracker }` opts shape is the same everywhere.
- **Residual gap (acceptable):** a whole-connector removal whose KV config is missing, or whose user never reconnects, could leave an account if Flow C's KV read returns nothing. Flow B cleans it on the next connect for that identity. A scheduled reaper (declined for this scope) would close this fully.
