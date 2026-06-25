# "Add connection" Activation Performance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make clicking "Add connection" (draft activation) return in time roughly constant in channel count, and make the activate path independent of how heavy any connector's `onChannelEnabled` is.

**Architecture:** Replace the serial per-channel `enableSync` loop in `activateDraft` with one `enableSyncBatch` call per provider that reads the channel-access tree once, builds the sync context once, and persists every selected channel's enabled state (Lever A). Then defer the connector's `onChannelEnabled` dispatch off the HTTP response into `executionCtx.waitUntil`, reusing a `recoverConnection`-style background dispatch; `recoverStuckSyncs` is the durability backstop (Lever B). Separately, parallelize the composite connector's channel enumeration so `onAuth`/`getChannels` stays synchronous but stops paying four serial round-trips.

**Tech Stack:** TypeScript, Cloudflare Workers, Hono, Kysely (Postgres), Durable Objects, Vitest. Connector code is in the `public/` git submodule (`@plotday/connector-google`).

## Global Constraints

- **No database schema changes.** All state used here (`channel`, `channel_config` KV, `twist_instance_connection.initial_sync_started_at`) already exists.
- **Do not change the shared `entrypoint.ts` dispatch handlers' inline behavior** (`callCallback` / `dispatchToTool`). Deferral is achieved by *not returning* the dispatch and scheduling a separate background invocation — never by adding a "deferred" flag to the dispatch loop.
- **Spans two repos:** `workers/api` (core, this repo) and the `public/` submodule (`connectors/google`, `connectors/AGENTS.md`). The submodule changes are a **separate PR**; the `composeChannels` and docs changes are independent of the core changes and can merge on their own. A connector change does **not** get a changeset (only `twister/` does).
- **Error capture:** any new `catch` block handling an *unexpected* error must call `captureException` (`tracker.captureException(...)`/`postHog.captureException(...)`); expected connector-dispatch failures log a `warn` only.
- **Lint must pass:** `pnpm lint` in `workers/api`; `pnpm exec tsc --noEmit` + `pnpm build` in `public/connectors/google`.
- **Worktree:** do this in an isolated worktree (touches core + submodule). The activate-loop tests hit the worktree DB via `$DATABASE_URL`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `public/connectors/google/src/compose.ts` | Compose product channels for the composite connector | Parallelize enumeration (Lever D) |
| `workers/api/src/twist/tools/integrations.ts` | Built-in Integrations tool (auth + channels) | Extract `buildOnChannelEnabledEntry`; add `enableSyncBatch`, `dispatchEnabledChannels` |
| `workers/api/src/twist/management.ts` | `activateDraft` + draft lifecycle | Extract `enableActivatedChannels`; return channel-dispatch descriptors |
| `workers/api/src/app/twists.ts` | `POST /twist/draft/:id/activate` route | Schedule deferred dispatch via `waitUntil` |
| `public/connectors/AGENTS.md` | Connector dev guide | Add connect/enable-path performance contract |
| Tests (new/updated) | see each task | |

---

## Increment 1 — Parallelize connector channel enumeration (public submodule, independent)

### Task 1: Parallelize `composeChannels`

**Files:**
- Modify: `public/connectors/google/src/compose.ts:31-50`
- Test: `public/connectors/google/src/compose.test.ts` (add to the existing file if present; otherwise create)

**Interfaces:**
- Consumes: `Product[]` (each with `requiredScopes: string[]`, `getRawChannels(token): Promise<Channel[]>`, `key`, `linkTypes`), `AuthToken`.
- Produces: `composeChannels(products, token): Promise<Channel[]>` — unchanged signature and output ordering (products in declaration order; channels in each product's order).

- [ ] **Step 1: Write the failing test** — concurrency + identical output.

```ts
import { describe, it, expect } from "vitest";
import { composeChannels } from "./compose";

function fakeProduct(key: string, scopes: string[], ids: string[], onCall: () => void) {
  return {
    key,
    requiredScopes: scopes,
    linkTypes: [{ type: `${key}-type`, label: key }],
    getRawChannels: async () => {
      onCall();
      // resolve on a later microtask so concurrency is observable
      await Promise.resolve();
      return ids.map((id) => ({ id, title: id }));
    },
  } as any;
}

describe("composeChannels", () => {
  it("enumerates eligible products concurrently and preserves order", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const bump = () => { inFlight++; maxInFlight = Math.max(maxInFlight, inFlight); };
    const products = [
      fakeProduct("mail", ["s.mail"], ["INBOX"], bump),
      fakeProduct("calendar", ["s.cal"], ["primary"], bump),
    ];
    const token = { token: "t", scopes: ["s.mail", "s.cal"] } as any;
    const out = await composeChannels(products, token);
    expect(out.map((c) => c.id)).toEqual(["mail:INBOX", "calendar:primary"]);
    expect(maxInFlight).toBe(2); // both started before either resolved → concurrent
  });

  it("skips products whose required scopes are not all granted", async () => {
    const products = [
      fakeProduct("mail", ["s.mail"], ["INBOX"], () => {}),
      fakeProduct("calendar", ["s.cal"], ["primary"], () => {}),
    ];
    const token = { token: "t", scopes: ["s.mail"] } as any;
    const out = await composeChannels(products, token);
    expect(out.map((c) => c.id)).toEqual(["mail:INBOX"]);
  });
});
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd public/connectors/google && pnpm vitest run src/compose.test.ts`
Expected: FAIL — `maxInFlight` is `1` with the current serial `for…await` loop.

- [ ] **Step 3: Implement the parallel version**

Replace the loop body of `composeChannels` (`compose.ts:35-49`) with:

```ts
  const grantedScopes = new Set(token.scopes ?? []);

  // Enumerate every eligible product concurrently (each getRawChannels is an
  // independent network call to Google). Order is preserved by enumerating
  // results in `eligible` order, which is products' declaration order.
  const eligible = products.filter((product) =>
    product.requiredScopes.every((s) => grantedScopes.has(s))
  );
  const perProduct = await Promise.all(
    eligible.map((product) => product.getRawChannels(token))
  );

  const result: Channel[] = [];
  eligible.forEach((product, i) => {
    for (const raw of perProduct[i]) {
      result.push(prefixChannel(product.key, raw, product.linkTypes));
    }
  });
  return result;
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd public/connectors/google && pnpm vitest run src/compose.test.ts`
Expected: PASS (both tests).

- [ ] **Step 5: Verify the connector still builds + full suite green**

Run: `cd public/connectors/google && pnpm exec tsc --noEmit && pnpm vitest run`
Expected: no type errors; existing `google`/`compose` tests pass.

- [ ] **Step 6: Commit (in the submodule)**

```bash
cd public && git add connectors/google/src/compose.ts connectors/google/src/compose.test.ts
git commit -m "perf(google): enumerate composite product channels concurrently"
```

---

## Increment 2 — Lever A: batch channel enable in `activateDraft` (core)

### Task 2: Extract `buildOnChannelEnabledEntry` from `applyChannelEnabled`

This is a behavior-preserving refactor that gives Lever B (Task 5) a way to build an `onChannelEnabled` dispatch entry **without** re-persisting state.

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (`applyChannelEnabled`, lines ~941-967)
- Test: `workers/api/src/twist/tools/integrations-enable-entry.test.ts` (new)

**Interfaces:**
- Produces: `private buildOnChannelEnabledEntry(provider: AuthProvider, channel: { id: string; title: string }, syncContext: SyncContext): any | null` — returns the source-pattern `{ sourceMethod, args, onFailure }` when `this.sourceProvider` is set, the legacy `{ optionPath, args, onFailure }` when a matching `providerConfigs` entry exists, else `null`. `args` is always `[{ id, title }, syncContext]`; `onFailure` is `{ functionName: "__failChannelSync", args: [provider, channel.id] }`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

const call = (host: any, ...args: any[]) =>
  (Integrations.prototype as any).buildOnChannelEnabledEntry.call(host, ...args);

describe("buildOnChannelEnabledEntry", () => {
  const channel = { id: "mail:INBOX", title: "Inbox" };
  const ctx = { recovering: false };

  it("source provider → sourceMethod entry with onFailure", () => {
    const entry = call({ sourceProvider: "google" }, "google", channel, ctx);
    expect(entry).toEqual({
      sourceMethod: "onChannelEnabled",
      args: [{ id: "mail:INBOX", title: "Inbox" }, ctx],
      onFailure: { functionName: "__failChannelSync", args: ["google", "mail:INBOX"] },
    });
  });

  it("legacy provider → optionPath entry", () => {
    const host = { sourceProvider: null, providerConfigs: [{ provider: "google" }] };
    const entry = call(host, "google", channel, ctx);
    expect(entry.optionPath).toEqual(["providers", 0, "onChannelEnabled"]);
    expect(entry.args).toEqual([{ id: "mail:INBOX", title: "Inbox" }, ctx]);
  });

  it("no matching provider → null", () => {
    const host = { sourceProvider: null, providerConfigs: [] };
    expect(call(host, "google", channel, ctx)).toBeNull();
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-entry.test.ts`
Expected: FAIL — `buildOnChannelEnabledEntry is not a function`.

- [ ] **Step 3: Add the helper and call it from `applyChannelEnabled`**

Add the method just below `applyChannelEnabled` (after line 968):

```ts
  /**
   * Build the `onChannelEnabled` dispatch entry for a channel WITHOUT
   * persisting anything. Shared by applyChannelEnabled (which persists first)
   * and dispatchEnabledChannels (background dispatch where state is already
   * persisted). `channel.title` must already be resolved by the caller.
   */
  private buildOnChannelEnabledEntry(
    provider: AuthProvider,
    channel: { id: string; title: string },
    syncContext: SyncContext
  ): any | null {
    const channelArg = { id: channel.id, title: channel.title };
    const onFailure = {
      functionName: "__failChannelSync",
      args: [provider, channel.id],
    };
    if (this.sourceProvider) {
      return { sourceMethod: "onChannelEnabled", args: [channelArg, syncContext], onFailure };
    }
    const providerIndex = this.providerConfigs.findIndex((p) => p.provider === provider);
    if (providerIndex < 0) return null;
    return {
      optionPath: ["providers", providerIndex, "onChannelEnabled"],
      args: [channelArg, syncContext],
      onFailure,
    };
  }
```

Then replace the tail of `applyChannelEnabled` (the `channelArg`/`onFailure`/source/legacy block, lines ~941-967) with:

```ts
    return this.buildOnChannelEnabledEntry(provider, { id: channel.id, title }, syncContext);
```

(`title` is the already-resolved `const title = channel.title ?? channel.id;` from the top of `applyChannelEnabled`.)

- [ ] **Step 4: Run the new test + the existing dispatch tests**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-entry.test.ts src/twist/tools/integrations-dispatch.test.ts src/twist/tools/integrations-seed-defaults.test.ts`
Expected: PASS (the seed-defaults test exercises `applyChannelEnabled` via its host stub, confirming the refactor preserved the returned entry shape).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations-enable-entry.test.ts
git commit -m "refactor(integrations): extract buildOnChannelEnabledEntry (behavior-preserving)"
```

### Task 3: Add `enableSyncBatch` to the Integrations tool

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (add method near `enableSync`, ~line 4007)
- Test: `workers/api/src/twist/tools/integrations-enable-batch.test.ts` (new)

**Interfaces:**
- Consumes: `getChannelAccess(provider, actorId)` (returns `Channel[]` tree), `findChannelInTree(tree, channelId)`, `buildSyncContext({ forActor, provider })`, `applyChannelEnabled(provider, actorId, channel, syncContext)` (Task 2).
- Produces: `async enableSyncBatch(provider: AuthProvider, channelIds: string[], actorId: ActorId, titles?: Record<string, string>): Promise<{ __dispatch: any[] } | undefined>` — reads the tree **once**, builds the sync context **once**, calls `applyChannelEnabled` per channel, returns the collected `onChannelEnabled` dispatch entries (so the entrypoint runs them inline, exactly like `enableSync` does today). Returns `undefined` when `channelIds` is empty or no entries were produced.

- [ ] **Step 1: Write the failing test** (host-stub style, mirrors `integrations-seed-defaults.test.ts`)

```ts
import { describe, it, expect } from "vitest";
import type { Channel } from "@plotday/twister/tools/integrations";
import { Integrations } from "./integrations";

function makeHost() {
  const calls = { getChannelAccess: 0, buildSyncContext: 0, applied: [] as string[] };
  const tree: Channel[] = [
    { id: "mail:INBOX", title: "Inbox" } as Channel,
    { id: "calendar:primary", title: "Primary" } as Channel,
  ];
  return {
    calls,
    db: { selectFrom: () => ({ select: () => ({ where: () => ({ where: () => ({ limit: () => ({ executeTakeFirst: async () => undefined }) }) }) }) }) },
    getChannelAccess: async () => { calls.getChannelAccess++; return tree; },
    findChannelInTree: (Integrations.prototype as any).findChannelInTree,
    buildSyncContext: async () => { calls.buildSyncContext++; return { recovering: false }; },
    applyChannelEnabled: async (_p: any, _a: any, channel: Channel) => {
      calls.applied.push(channel.id);
      return { sourceMethod: "onChannelEnabled", args: [{ id: channel.id }, {}] };
    },
    enableSyncBatch: (Integrations.prototype as any).enableSyncBatch,
  } as any;
}

describe("enableSyncBatch", () => {
  it("reads the tree once, builds context once, applies each channel, returns one __dispatch", async () => {
    const host = makeHost();
    const out = await host.enableSyncBatch.call(host, "google", ["mail:INBOX", "calendar:primary"], "actor-1");
    expect(host.calls.getChannelAccess).toBe(1);
    expect(host.calls.buildSyncContext).toBe(1);
    expect(host.calls.applied).toEqual(["mail:INBOX", "calendar:primary"]);
    expect(out.__dispatch).toHaveLength(2);
  });

  it("returns undefined for an empty channel list", async () => {
    const host = makeHost();
    expect(await host.enableSyncBatch.call(host, "google", [], "actor-1")).toBeUndefined();
    expect(host.calls.getChannelAccess).toBe(0);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-batch.test.ts`
Expected: FAIL — `enableSyncBatch is not a function`.

- [ ] **Step 3: Implement `enableSyncBatch`** (insert right after `enableSync`, before `disableSync` at line 4009)

```ts
  /**
   * Enable several channels for one provider in a single call. The activation
   * path used to call enableSync once per channel — each a full callCallback
   * round-trip into the runtime that re-read the entire channel-access tree and
   * rebuilt the sync context. This reads the tree once and builds the context
   * once, then persists each channel's enabled state, collecting the
   * onChannelEnabled dispatch entries. Returns them as a single `__dispatch` so
   * the entrypoint runs them inline (same semantics as enableSync). Lever B
   * (dispatchEnabledChannels) later moves the dispatch off the response.
   */
  async enableSyncBatch(
    provider: AuthProvider,
    channelIds: string[],
    actorId: ActorId,
    titles?: Record<string, string>
  ): Promise<{ __dispatch: any[] } | undefined> {
    if (!channelIds || channelIds.length === 0) return;

    const tree = await this.getChannelAccess(provider, actorId);
    const syncContext = await this.buildSyncContext({ forActor: actorId, provider });

    const entries: any[] = [];
    for (const channelId of channelIds) {
      const channelObj = this.findChannelInTree(tree, channelId);
      const title = titles?.[channelId] ?? channelObj?.title;

      // Per-channel linkTypes fallback — mirrors enableSync (integrations.ts
      // ~3942-3958): if KV has no linkTypes, reuse an existing channel row's.
      let linkTypes = channelObj?.linkTypes ?? null;
      if (!linkTypes) {
        const existingChannel = await this.db
          .selectFrom("channel")
          .select("link_types")
          .where("channel_id", "=", channelId)
          .where("link_types", "is not", null)
          .limit(1)
          .executeTakeFirst();
        if (existingChannel?.link_types) {
          try {
            linkTypes = typeof existingChannel.link_types === "string"
              ? JSON.parse(existingChannel.link_types)
              : existingChannel.link_types;
          } catch { /* ignore parse errors */ }
        }
      }

      const channel: Channel = {
        id: channelId,
        title: title ?? channelId,
        ...(linkTypes ? { linkTypes } : {}),
      };
      const entry = await this.applyChannelEnabled(provider, actorId, channel, syncContext);
      if (entry) entries.push(entry);
    }

    if (entries.length > 0) return { __dispatch: entries };
  }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-batch.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations-enable-batch.test.ts
git commit -m "feat(integrations): add enableSyncBatch (read tree + context once)"
```

### Task 4: Use one `enableSyncBatch` per provider in `activateDraft`

**Files:**
- Modify: `workers/api/src/twist/management.ts` (extract the channel-enable block, ~lines 1131-1224, into an exported function; call it from `activateDraft`)
- Test: `workers/api/src/twist/management-enable-channels.test.ts` (new)

**Interfaces:**
- Produces: `export async function enableActivatedChannels(twistWrapper: { callCallback: (...a: any[]) => Promise<any> }, integrationsMap: Record<string, string>, syncables: Array<{ provider: string; syncableId: string }>, actorId: string, logger: { warn: (...a: any[]) => void }): Promise<void>` — groups `syncables` by provider and, per provider, issues exactly one `callCallback(path, "enableSyncBatch", provider, channelIds, actorId, undefined)` plus one `initAutoEnableDefault` and one `initAutoThreadingDefault`.

- [ ] **Step 1: Write the failing test** (spy wrapper asserts O(1) calls)

```ts
import { describe, it, expect } from "vitest";
import { enableActivatedChannels } from "./management";

function spyWrapper() {
  const calls: Array<{ method: string; args: any[] }> = [];
  return {
    calls,
    wrapper: {
      callCallback: async (_path: string[], method: string, ...args: any[]) => {
        calls.push({ method, args });
        return undefined;
      },
    },
  };
}

describe("enableActivatedChannels", () => {
  it("issues one enableSyncBatch per provider regardless of channel count", async () => {
    const { wrapper, calls } = spyWrapper();
    const syncables = [
      { provider: "google", syncableId: "mail:INBOX" },
      { provider: "google", syncableId: "calendar:primary" },
      { provider: "google", syncableId: "tasks:list1" },
      { provider: "google", syncableId: "contacts:all" },
    ];
    await enableActivatedChannels(wrapper as any, { google: "tools:integrations" }, syncables, "actor-1", console);

    const batch = calls.filter((c) => c.method === "enableSyncBatch");
    expect(batch).toHaveLength(1);
    expect(batch[0].args[0]).toBe("google");
    expect(batch[0].args[1]).toEqual(["mail:INBOX", "calendar:primary", "tasks:list1", "contacts:all"]);
    expect(calls.filter((c) => c.method === "initAutoEnableDefault")).toHaveLength(1);
    expect(calls.filter((c) => c.method === "initAutoThreadingDefault")).toHaveLength(1);
    // No per-channel enableSync calls remain.
    expect(calls.some((c) => c.method === "enableSync")).toBe(false);
  });

  it("skips providers with no integrations path", async () => {
    const { wrapper, calls } = spyWrapper();
    await enableActivatedChannels(wrapper as any, {}, [{ provider: "google", syncableId: "mail:INBOX" }], "actor-1", { warn: () => {} });
    expect(calls).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/management-enable-channels.test.ts`
Expected: FAIL — `enableActivatedChannels is not exported`.

- [ ] **Step 3: Add the exported function** (in `management.ts`, above `activateDraft`)

```ts
/** Dispose an RPC stub returned by callCallback, if it is disposable. */
function disposeRpcResult(result: unknown): void {
  if (result && typeof result === "object" && Symbol.dispose in result) {
    (result as any)[Symbol.dispose]();
  }
}

/**
 * Enable the user's selected channels during draft activation. One
 * `enableSyncBatch` callCallback per provider (instead of one enableSync per
 * channel) plus the per-provider auto-enable / auto-threading default seeds.
 */
export async function enableActivatedChannels(
  twistWrapper: { callCallback: (path: string[], method: string, ...args: any[]) => Promise<any> },
  integrationsMap: Record<string, string>,
  syncables: Array<{ provider: string; syncableId: string }>,
  actorId: string,
  logger: { warn: (msg: string, meta?: any) => void }
): Promise<void> {
  const byProvider = new Map<string, string[]>();
  for (const { provider, syncableId } of syncables) {
    const list = byProvider.get(provider) ?? [];
    list.push(syncableId);
    byProvider.set(provider, list);
  }

  for (const [provider, channelIds] of byProvider) {
    const integrationsPath = integrationsMap[provider];
    if (!integrationsPath) {
      logger.warn("No integrations path found for provider during activation", {
        provider,
        available_providers: Object.keys(integrationsMap),
      });
      continue;
    }
    const path = integrationsPath.split(":");

    try {
      disposeRpcResult(
        await twistWrapper.callCallback(path, "enableSyncBatch", provider, channelIds, actorId, undefined)
      );
    } catch (error) {
      logger.warn("Failed to enable channels during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
    }

    try {
      disposeRpcResult(await twistWrapper.callCallback(path, "initAutoEnableDefault", provider, actorId));
    } catch (error) {
      logger.warn("Failed to seed auto-enable default during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
    }
    try {
      disposeRpcResult(await twistWrapper.callCallback(path, "initAutoThreadingDefault", provider, actorId));
    } catch (error) {
      logger.warn("Failed to seed auto-threading default during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
    }
  }
}
```

- [ ] **Step 4: Replace the inline loop in `activateDraft`**

In `activateDraft`, replace the entire `if (contact) { … }` channel-enable block (the body from the `for (const { provider, syncableId } of syncables)` loop through the `initAutoThreadingDefault` block, ~lines 1131-1223) with:

```ts
    if (contact) {
      const twistWrapper = await activate.twistFactory({ twistInstanceId: draftId });
      await enableActivatedChannels(twistWrapper, integrationsMap, syncables, contact.id, logger);
    }
```

Leave the surrounding `if (syncables && syncables.length > 0)` / `integrationsMap` / `contact` lookups intact.

- [ ] **Step 5: Run the new test + the existing management test**

Run: `cd workers/api && pnpm vitest run src/twist/management-enable-channels.test.ts src/twist/management.test.ts`
Expected: PASS.

- [ ] **Step 6: Lint + commit**

```bash
cd workers/api && pnpm lint
git add workers/api/src/twist/management.ts workers/api/src/twist/management-enable-channels.test.ts
git commit -m "perf(activate): batch channel-enable into one enableSyncBatch per provider"
```

**At this point Lever A is complete and independently shippable** — "Add connection" no longer does N round-trips into the runtime. Increment 3 removes the remaining inline `onChannelEnabled` work from the response.

---

## Increment 3 — Lever B: defer `onChannelEnabled` off the response (core)

### Task 5: Add `dispatchEnabledChannels` to the Integrations tool

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (add near `recoverConnection`, ~line 1079)
- Test: `workers/api/src/twist/tools/integrations-dispatch-enabled.test.ts` (new)

**Interfaces:**
- Consumes: `buildSyncContext({})`, `store.get<ChannelConfig>("channel_config:<provider>:<channelId>")`, `buildOnChannelEnabledEntry` (Task 2).
- Produces: `async dispatchEnabledChannels(provider: AuthProvider, _actorId: ActorId, channelIds: string[]): Promise<{ __dispatch: any[] } | undefined>` — builds an `onChannelEnabled` dispatch entry (NON-recovery, `recovering: false`) for each still-enabled channel and returns them as `__dispatch`. Persists nothing (state was persisted by `enableSyncBatch`). Returns `undefined` when nothing is enabled.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

function makeHost(enabled: Record<string, boolean>) {
  return {
    sourceProvider: "google",
    buildSyncContext: async () => ({ recovering: false }),
    buildOnChannelEnabledEntry: (Integrations.prototype as any).buildOnChannelEnabledEntry,
    store: {
      get: async (key: string) => {
        const id = key.replace("channel_config:google:", "");
        return enabled[id] ? { enabled: true, title: id } : { enabled: false, title: id };
      },
    },
    dispatchEnabledChannels: (Integrations.prototype as any).dispatchEnabledChannels,
  } as any;
}

describe("dispatchEnabledChannels", () => {
  it("emits a non-recovery onChannelEnabled dispatch per still-enabled channel", async () => {
    const host = makeHost({ "mail:INBOX": true, "calendar:primary": true });
    const out = await host.dispatchEnabledChannels.call(host, "google", "actor-1", ["mail:INBOX", "calendar:primary"]);
    expect(out.__dispatch).toHaveLength(2);
    expect(out.__dispatch[0]).toMatchObject({ sourceMethod: "onChannelEnabled" });
    expect(out.__dispatch[0].args[1]).toEqual({ recovering: false });
  });

  it("skips channels that are no longer enabled and returns undefined when none remain", async () => {
    const host = makeHost({ "mail:INBOX": false });
    expect(await host.dispatchEnabledChannels.call(host, "google", "actor-1", ["mail:INBOX"])).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-dispatch-enabled.test.ts`
Expected: FAIL — `dispatchEnabledChannels is not a function`.

- [ ] **Step 3: Implement `dispatchEnabledChannels`** (add immediately after `recoverConnection`)

```ts
  /**
   * Background re-dispatch of `onChannelEnabled` for channels that were just
   * enabled by enableSyncBatch with dispatch deferred. State is already
   * persisted, so this builds the dispatch entries only (no re-persist). Uses a
   * NON-recovery context (a fresh initial sync) — unlike recoverConnection,
   * which re-walks history with `recovering: true`. Invoked off the activate
   * HTTP response via executionCtx.waitUntil; recoverStuckSyncs is the backstop
   * if this never runs.
   */
  async dispatchEnabledChannels(
    provider: AuthProvider,
    _actorId: ActorId,
    channelIds: string[]
  ): Promise<{ __dispatch: any[] } | undefined> {
    if (!channelIds || channelIds.length === 0) return;
    const syncContext = await this.buildSyncContext({});
    const entries: any[] = [];
    for (const channelId of channelIds) {
      const config = await this.store.get<ChannelConfig>(
        `channel_config:${provider}:${channelId}`
      );
      if (!config?.enabled) continue;
      const entry = this.buildOnChannelEnabledEntry(
        provider,
        { id: channelId, title: config.title ?? channelId },
        syncContext
      );
      if (entry) entries.push(entry);
    }
    if (entries.length > 0) return { __dispatch: entries };
  }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-dispatch-enabled.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations-dispatch-enabled.test.ts
git commit -m "feat(integrations): add dispatchEnabledChannels for deferred onChannelEnabled"
```

### Task 6: Make `enableSyncBatch` persist-only and have `enableActivatedChannels` return descriptors

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (`enableSyncBatch` — add `options.dispatch`)
- Modify: `workers/api/src/twist/management.ts` (`enableActivatedChannels` — pass `dispatch: false`, return descriptors)
- Test: update `workers/api/src/twist/management-enable-channels.test.ts`; add to `integrations-enable-batch.test.ts`

**Interfaces:**
- `enableSyncBatch(provider, channelIds, actorId, titles?, options?: { dispatch?: boolean })` — when `options.dispatch === false`, persists every channel's state but returns `undefined` (no inline `__dispatch`). Default (omitted/true) is unchanged.
- `enableActivatedChannels(...)` now returns `Promise<Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }>>` — one descriptor per provider that was enabled, for the caller to dispatch in the background.

- [ ] **Step 1: Update the failing tests first**

In `integrations-enable-batch.test.ts`, add:

```ts
  it("with { dispatch: false } persists channels but returns no __dispatch", async () => {
    const host = makeHost();
    const out = await host.enableSyncBatch.call(host, "google", ["mail:INBOX"], "actor-1", undefined, { dispatch: false });
    expect(host.calls.applied).toEqual(["mail:INBOX"]); // still persisted
    expect(out).toBeUndefined();
  });
```

In `management-enable-channels.test.ts`, change the first test to also assert deferral + descriptors:

```ts
    // enableSyncBatch is called with dispatch:false (5th positional arg = options)
    expect(batch[0].args[4]).toEqual({ dispatch: false });

    const descriptors = await enableActivatedChannels(wrapper as any, { google: "tools:integrations" }, syncables, "actor-1", console);
    expect(descriptors).toEqual([
      { provider: "google", actorId: "actor-1", channelIds: ["mail:INBOX", "calendar:primary", "tasks:list1", "contacts:all"], integrationsPath: "tools:integrations" },
    ]);
```

(Adjust the earlier `await enableActivatedChannels(...)` in that test to capture the return value.)

- [ ] **Step 2: Run, verify failure**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-batch.test.ts src/twist/management-enable-channels.test.ts`
Expected: FAIL — option not honored / function returns `void`.

- [ ] **Step 3: Add the `options` param to `enableSyncBatch`**

Change the signature and the final return:

```ts
  async enableSyncBatch(
    provider: AuthProvider,
    channelIds: string[],
    actorId: ActorId,
    titles?: Record<string, string>,
    options?: { dispatch?: boolean }
  ): Promise<{ __dispatch: any[] } | undefined> {
```

…and replace the final `if (entries.length > 0) return { __dispatch: entries };` with:

```ts
    // Lever B: when the caller will dispatch onChannelEnabled in the background,
    // persist state (above) but do not run the dispatch inline.
    if (options?.dispatch === false) return;
    if (entries.length > 0) return { __dispatch: entries };
```

- [ ] **Step 4: Update `enableActivatedChannels` to defer + return descriptors**

Change its return type to `Promise<Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }>>`, pass `{ dispatch: false }` to the batch call, and collect descriptors:

```ts
  const descriptors: Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }> = [];

  for (const [provider, channelIds] of byProvider) {
    const integrationsPath = integrationsMap[provider];
    if (!integrationsPath) {
      logger.warn(/* unchanged */);
      continue;
    }
    const path = integrationsPath.split(":");

    try {
      disposeRpcResult(
        await twistWrapper.callCallback(path, "enableSyncBatch", provider, channelIds, actorId, undefined, { dispatch: false })
      );
      descriptors.push({ provider, actorId, channelIds, integrationsPath });
    } catch (error) {
      logger.warn("Failed to enable channels during activation", {
        provider,
        error_message: error instanceof Error ? error.message : String(error),
      });
    }

    // initAutoEnableDefault / initAutoThreadingDefault blocks unchanged …
  }

  return descriptors;
```

- [ ] **Step 5: Run the tests, verify pass**

Run: `cd workers/api && pnpm vitest run src/twist/tools/integrations-enable-batch.test.ts src/twist/management-enable-channels.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/management.ts workers/api/src/twist/tools/integrations-enable-batch.test.ts workers/api/src/twist/management-enable-channels.test.ts
git commit -m "feat(activate): persist channels synchronously, return dispatch descriptors"
```

### Task 7: Return descriptors from `activateDraft` and schedule the deferred dispatch in the route

**Files:**
- Modify: `workers/api/src/twist/management.ts` (`activateDraft` returns descriptors)
- Modify: `workers/api/src/app/twists.ts` (route schedules `waitUntil` dispatch)
- Test: `workers/api/src/twist/management-enable-channels.test.ts` (assert `activateDraft` plumbs descriptors — light integration), plus manual verification note.

**Interfaces:**
- `activateDraft(...)` now resolves to `{ draft: <existing row>, channelDispatch: Array<{ provider, actorId, channelIds, integrationsPath }> }`. (Only caller is the route — Step 4 updates it.)

- [ ] **Step 1: Thread descriptors out of `activateDraft`**

In `activateDraft`, capture the descriptors and include them in the return. Change the `if (contact)` block:

```ts
    let channelDispatch: Array<{ provider: string; actorId: string; channelIds: string[]; integrationsPath: string }> = [];
    if (contact) {
      const twistWrapper = await activate.twistFactory({ twistInstanceId: draftId });
      channelDispatch = await enableActivatedChannels(twistWrapper, integrationsMap, syncables, contact.id, logger);
    }
```

Declare `let channelDispatch: …[] = [];` at the top of the `if (syncables && syncables.length > 0)` block (so the final `return` can see it), and change the function's final `return draft;` to:

```ts
  return { draft, channelDispatch };
```

Also handle the no-channels branch: in the `} else {` (no channels) path, `channelDispatch` stays `[]`. Ensure `channelDispatch` is declared in function scope (declare `let channelDispatch: …[] = [];` right before the `if (syncables …)` guard).

- [ ] **Step 2: Add imports to the route** (`workers/api/src/app/twists.ts`, top of file)

```ts
import { createDb } from "../db";
import { twistFactory } from "../twist/factory";
import { createLogger } from "@plotday/worker-util";
```

(Skip any that are already imported.)

- [ ] **Step 3: Schedule the deferred dispatch after `activateDraft`**

Replace the `await activateDraft(...)` call + `notifyUserSync` (route lines 432-452) with:

```ts
    const { channelDispatch } = await activateDraft(
      c.var.db,
      c.env,
      draftId,
      body.priorityId,
      body.name,
      body.config,
      body.syncables,
      {
        twistFactory: twistFactory({
          env: c.env,
          ctx: c.executionCtx as ExecutionContext,
          db: c.var.db,
        }),
      },
      body.teamId
    );

    notifyUserSync(c, c.var.user.id);

    // Lever B: run onChannelEnabled OFF the response. The request-scoped db is
    // torn down after we return, so the background task opens its own db and a
    // fresh twist factory (see AGENTS "Never use c.var.db inside waitUntil").
    // If this is ever lost (eviction), recoverStuckSyncs re-dispatches.
    if (channelDispatch.length > 0) {
      const env = c.env;
      const tracker = c.var.tracker;
      c.executionCtx.waitUntil((async () => {
        const bgLogger = createLogger({ twist_instance_id: draftId });
        const bgDb = createDb(env);
        try {
          const wrapper = await twistFactory({
            env,
            ctx: c.executionCtx as ExecutionContext,
            db: bgDb,
          })({ twistInstanceId: draftId });
          for (const d of channelDispatch) {
            try {
              const result = await wrapper.callCallback(
                d.integrationsPath.split(":"),
                "dispatchEnabledChannels",
                d.provider,
                d.actorId,
                d.channelIds
              );
              if (result && typeof result === "object" && Symbol.dispose in result) {
                (result as any)[Symbol.dispose]();
              }
            } catch (error) {
              bgLogger.warn("Deferred onChannelEnabled dispatch failed", {
                provider: d.provider,
                error_message: error instanceof Error ? error.message : String(error),
              });
            }
          }
        } catch (error) {
          bgLogger.error("Deferred channel dispatch setup failed", error as Error);
          tracker?.captureException(error as Error);
        } finally {
          await bgDb.destroy();
        }
      })());
    }

    return c.json({ success: true });
```

- [ ] **Step 4: Type-check + run the affected suites**

Run: `cd workers/api && pnpm exec tsc --noEmit && pnpm vitest run src/twist/management-enable-channels.test.ts src/twist/tools/integrations-enable-batch.test.ts src/twist/tools/integrations-dispatch-enabled.test.ts`
Expected: no type errors; PASS. (The `activateDraft` return-shape change compiles against the updated route.)

- [ ] **Step 5: Lint + commit**

```bash
cd workers/api && pnpm lint
git add workers/api/src/twist/management.ts workers/api/src/app/twists.ts
git commit -m "perf(activate): defer onChannelEnabled dispatch off the activate response"
```

- [ ] **Step 6: Manual verification (worktree, optional but recommended)**

Connect a Google composite account locally with several channels selected; confirm "Add connection" returns quickly and the connection then shows "Syncing X" that resolves. (Full e2e needs OAuth + a tunnel; the unit tests cover the logic.)

---

## Increment 4 — Guidance (public submodule)

### Task 8: Document the connect/enable-path performance contract

**Files:**
- Modify: `public/connectors/AGENTS.md` (extend the `onChannelEnabled` pitfall #15 area / add a short section)
- Modify: `workers/api/src/twist/tools/integrations.ts` (one-line pointer comment at `enableSyncBatch` — already added in Task 3; verify it references the doc)

- [ ] **Step 1: Add the contract to `connectors/AGENTS.md`**

Under the existing `## Integrations (auth + channels)` section (or just after the `onChannelEnabled` skeleton notes), add:

```markdown
### Connect / enable-path performance contract

The connect and channel-enable paths are on the user's critical path. The
runtime keeps them fast, and connectors must not undo that:

- **`getChannels` runs synchronously during connect.** Keep it lean and
  **parallelize independent enumeration** — when you list resources across
  several products/APIs, run them with `Promise.all`, never a serial
  `for … await` loop (see `connectors/google/src/compose.ts`). A serial loop
  pays the sum of every round-trip while the user waits.
- **`onChannelEnabled` is dispatched OFF the user's critical path.** When a user
  activates a connection, the runtime persists the enabled-channel state
  synchronously and runs `onChannelEnabled` in the background. So: never assume
  `onChannelEnabled` has run by the time the user sees the connection, and keep
  using `runTask()` for webhook setup and initial sync — the background dispatch
  still has the normal per-execution budget. Heavy *inline* work in
  `onChannelEnabled` (or in `getChannels` on enable) is the recurring mistake;
  the activate path used to do an inline `getChannels` that paginated every
  Google Drive folder and blocked for seconds.
```

- [ ] **Step 2: Validate the doc + commit (submodule)**

Run: `cd public && git add connectors/AGENTS.md && git commit -m "docs(connectors): connect/enable-path performance contract"`
Expected: committed. (No changeset — connector/doc changes under `public/` outside `twister/` don't get one.)

---

## Self-Review

**Spec coverage:**
- Lever A (collapse serial loop, de-N+1) → Tasks 2-4. ✓
- Lever B (defer onChannelEnabled, durable via recoverStuckSyncs) → Tasks 5-7. ✓
- §D (parallelize composeChannels, onAuth stays synchronous) → Task 1. ✓
- §C (guidance so connectors don't reintroduce) → Task 8 + comments in Tasks 3/5. ✓
- Testing (round-trip-count regression, persistence, deferral) → Tasks 1,3,4,5,6. ✓
- No schema changes; no entrypoint dispatch-loop change → honored throughout. ✓
- PR split (core vs public) → Tasks 1 & 8 commit in the submodule; 2-7 in core. ✓

**Type consistency:** `enableSyncBatch(provider, channelIds, actorId, titles?, options?)`, `dispatchEnabledChannels(provider, actorId, channelIds)`, `buildOnChannelEnabledEntry(provider, channel, syncContext)`, `enableActivatedChannels(...) → descriptors[]`, `activateDraft(...) → { draft, channelDispatch }` are used consistently across Tasks 2-7. Descriptor shape `{ provider, actorId, channelIds, integrationsPath }` is identical in management.ts and the route. ✓

**Placeholder scan:** every step has concrete code/commands and expected output. The only deferred decision (queue vs. waitUntil for Lever B) was resolved to `waitUntil` + `recoverStuckSyncs` backstop, with the queue noted as a future hardening option in the spec — not a placeholder in this plan. ✓

## Notes / future hardening (not in scope)

- If the 30-min `recoverStuckSyncs` backstop window is ever judged too loose for
  lost deferred dispatches, upgrade Task 7's `waitUntil` to a durable run-queue
  enqueue (`Tasks` → `this.queue.send`, consumed by `Tasks.processQueue` →
  `invokeWebhookCallback`). The mechanism exists; it needs a callback token to
  `dispatchEnabledChannels`. Out of scope here — `waitUntil` + the watchdog
  already guarantees eventual delivery.
- Parallelizing the per-channel `applyChannelEnabled` writes inside
  `enableSyncBatch` (`Promise.all`) is a possible further win but contends on the
  single `twist_instance_connection` row via `markChannelSyncStarted`; left
  sequential for safety since the dominant cost (N round-trips into the runtime)
  is already gone.
```
