# Trello Auth Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native `AuthProvider.Trello` to the Plot runtime so users authorize Trello via its `trello.com/1/authorize` token-fragment flow (not OAuth 2.0), giving a real "Connect" UX that later powers the Trello connector.

**Architecture:** Trello returns its access token in the URL **fragment** (`#token=…`) with no code exchange and no refresh. The existing runtime is a pure OAuth2-authorization-code engine, so we add a third `authMode: "token-fragment"` and branch three places: `GenerateAuthUrl` (build Trello's authorize URL), the auth **bridge** (read the fragment client-side and relay the token to the server), and `HandleOauthCallback` (skip the code exchange, use the relayed token). Trello's API key/secret reach the connector by injecting them into the `AuthToken` at `integrations.get()` time from `env` (never persisted). The Trello API key is non-secret; the app secret is sensitive but never leaves the server.

**Tech Stack:** TypeScript, Cloudflare Workers, Hono, vitest, `@plotday/twister` (pnpm workspace link, public submodule), Durable Objects (auth-state storage).

## Global Constraints

- **This plan is Plan 1 of the Trello effort.** It is the prerequisite for the connector (Plan 2). Spec: `docs/superpowers/specs/2026-06-25-trello-connector-design.md` (Part 1).
- **Work in the worktree:** `/Users/kris.braun/code/plot/.claude/worktrees/trello-connector` on branch `trello-connector`. The `public/` submodule changes go on a submodule branch (see Task 1).
- **Two repos:** the enum + changeset live in the `public/` submodule (`public/twister`); everything else in the main repo (`workers/api`). Commit them separately.
- **Twister changeset is REQUIRED** for any change under `public/twister/src/` (`@plotday/twister: minor`, summary starts with `Added:`). Connectors never get a changeset.
- **Trello authorize params are fixed:** `key={AUTH_TRELLO_ID}`, `response_type=token`, `scope=read,write`, `expiration=never`, `name=Plot`, `return_url={API_ROOT}/auth/bridge?state={state}`. Trello uses `key`/`return_url` (NOT `client_id`/`redirect_uri`) and does **not** echo a `state` param, so `state` is carried in the `return_url` query.
- **Env var names (exact):** `AUTH_TRELLO_ID` (the Trello API key) and `AUTH_TRELLO_SECRET` (the Trello app secret, for later webhook HMAC). `*_ID`/`*_SECRET` matter: the deploy pipeline treats names matching `SECRET|KEY|TOKEN` as Cloudflare secrets.
- **Provisioning is out of scope** (human-gated): creating the Trello app key, 1Password, `sync-github-secrets`. End-to-end auth can't be exercised locally without it; unit tests cover everything we can verify.
- **Error capture:** any new `catch` for an unexpected error calls `tracker.captureException(error)` / `postHog.captureException(...)`. Expected user-facing auth failures return a `Response`, they don't throw.
- **Run a single test file:** `cd workers/api && pnpm vitest run <path>` (unit tests are `src/**/*.test.ts`, config `workers/api/vitest.config.ts`).
- **Never** hardcode the Trello API key/secret in any committed source — always read from `env`/`PROVIDER_CONFIGS` lookups.

---

### Task 1: `AuthProvider.Trello` enum + changeset (public submodule)

**Files:**
- Modify: `public/twister/src/tools/integrations.ts:643-668` (the `AuthProvider` enum)
- Create: `public/.changeset/trello-auth-provider.md`

**Interfaces:**
- Produces: `AuthProvider.Trello = "trello"` — consumed by every later task (the `PROVIDER_CONFIGS` Record key, the connector's `readonly provider`).

- [ ] **Step 1: Create the submodule branch and rebuild baseline**

The Trello provider work touches the public submodule. Create a branch there first.

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public
git checkout -b trello-connector
```

- [ ] **Step 2: Add the enum value**

In `public/twister/src/tools/integrations.ts`, add to the `AuthProvider` enum (after `Airtable`):

```typescript
  /** Airtable OAuth provider for Airtable bases */
  Airtable = "airtable",
  /** Trello token-authorize provider (not OAuth 2.0 — token returned in URL fragment) */
  Trello = "trello",
}
```

- [ ] **Step 3: Add the changeset**

Create `public/.changeset/trello-auth-provider.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `AuthProvider.Trello` for the Trello connector's token-authorize flow.
```

- [ ] **Step 4: Build twister and validate the changeset**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/twister && pnpm build
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public && pnpm validate-changesets
```
Expected: twister builds with no TS errors; `validate-changesets` passes.

- [ ] **Step 5: Refresh the workspace link**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector && pnpm install
```
Expected: install completes; `AuthProvider.Trello` is now importable from `@plotday/twister` in the main repo. (`workers/api` will not fully typecheck until Task 2 adds the `PROVIDER_CONFIGS.trello` entry — that's expected and fixed next.)

- [ ] **Step 6: Commit (in the submodule)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public
git add twister/src/tools/integrations.ts .changeset/trello-auth-provider.md
git commit -m "feat(twister): add AuthProvider.Trello"
```

---

### Task 2: Trello provider config + env bindings (`provider.ts`, `env.ts`, `package.json`)

**Files:**
- Modify: `workers/api/src/provider.ts` — `ProviderConfig.authMode` union (~401), `ProviderData` union (~85), add `TrelloProviderData` (~near 43), add `parseTrelloTokenResponse` (~near 267), add `trello` to `PROVIDER_CONFIGS` (~after 657), add `extractUserId` case (~451)
- Modify: `workers/api/src/env.ts:188-207` (Bindings)
- Modify: `workers/api/package.json` (`config.deploy_vars`)
- Test: `workers/api/src/provider.trello.test.ts` (new)

**Interfaces:**
- Consumes: `AuthProvider.Trello` (Task 1).
- Produces:
  - `type TrelloProviderData = { memberId: string; username: string | null; fullName: string | null }`
  - `parseTrelloTokenResponse(response: any): Promise<TrelloProviderData | undefined>` — reads `response.access_token` + `response.key`, fetches `https://api.trello.com/1/members/me`.
  - `PROVIDER_CONFIGS.trello` with `authMode: "token-fragment"`, `authUrl`, `requiresHttpsRedirect: true`, `parseTokenResponse`, `extractMetadata` → `{ memberId }`, `extractAccountLabel`.
  - `env.AUTH_TRELLO_ID`, `env.AUTH_TRELLO_SECRET` on `Bindings`.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/provider.trello.test.ts`:

```typescript
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  PROVIDER_CONFIGS,
  parseTrelloTokenResponse,
  extractUserId,
  type TrelloProviderData,
} from "./provider";

afterEach(() => vi.restoreAllMocks());

describe("trello provider config", () => {
  it("is a token-fragment provider with no tokenUrl", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.authMode).toBe("token-fragment");
    expect(cfg.authUrl).toBe("https://trello.com/1/authorize");
    expect(cfg.tokenUrl).toBeUndefined();
    expect(cfg.requiresHttpsRedirect).toBe(true);
  });

  it("extractAccountLabel prefers fullName, falls back to username", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.extractAccountLabel?.({ memberId: "m1", username: "u", fullName: "Full" } as TrelloProviderData)).toBe("Full");
    expect(cfg.extractAccountLabel?.({ memberId: "m1", username: "u", fullName: null } as TrelloProviderData)).toBe("u");
  });

  it("extractMetadata exposes the member id", () => {
    const cfg = PROVIDER_CONFIGS.trello;
    expect(cfg.extractMetadata?.({ memberId: "m1", username: "u", fullName: "F" } as TrelloProviderData)).toEqual({ memberId: "m1" });
  });
});

describe("parseTrelloTokenResponse", () => {
  it("fetches /members/me with the key+token and maps the result", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ id: "member-123", username: "kris", fullName: "Kris B" }), { status: 200 }),
    );
    const data = await parseTrelloTokenResponse({ access_token: "tok-abc", key: "key-xyz" });
    expect(data).toEqual({ memberId: "member-123", username: "kris", fullName: "Kris B" });
    const calledUrl = fetchMock.mock.calls[0][0] as string;
    expect(calledUrl).toContain("https://api.trello.com/1/members/me");
    expect(calledUrl).toContain("key=key-xyz");
    expect(calledUrl).toContain("token=tok-abc");
  });

  it("returns undefined when there is no access_token", async () => {
    expect(await parseTrelloTokenResponse({ key: "key-xyz" })).toBeUndefined();
  });

  it("returns undefined on a non-ok response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("nope", { status: 401 }));
    expect(await parseTrelloTokenResponse({ access_token: "t", key: "k" })).toBeUndefined();
  });
});

describe("extractUserId", () => {
  it("returns the trello member id", () => {
    expect(extractUserId("trello" as any, { memberId: "member-123", username: "k", fullName: "K" } as TrelloProviderData)).toBe("member-123");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm vitest run src/provider.trello.test.ts
```
Expected: FAIL — `parseTrelloTokenResponse` / `TrelloProviderData` not exported, `PROVIDER_CONFIGS.trello` undefined.

- [ ] **Step 3: Implement the provider config**

In `workers/api/src/provider.ts`:

(a) Extend the `authMode` union (~line 401):

```typescript
  authMode?: "oauth" | "hosted" | "token-fragment";
```

(b) Add the type next to `AtlassianProviderData` (~line 46):

```typescript
export type TrelloProviderData = {
  memberId: string;
  username: string | null;
  fullName: string | null;
};
```

(c) Add `TrelloProviderData` to the `ProviderData` union (~line 96):

```typescript
  | AirtableProviderData
  | TrelloProviderData
  | HostedAccountProviderData;
```

(d) Add the parse helper next to `parseAtlassianTokenResponse` (~line 276). It reads the API key from the synthesized token response (`response.key`) so it needs no `env` access:

```typescript
// Trello returns the token in the authorize fragment (no code exchange), so the
// "token response" is synthesized by HandleOauthCallback as { access_token, key }.
// We read the app key from there to call the members API for the account label.
const parseTrelloTokenResponse = async (
  response: any
): Promise<TrelloProviderData | undefined> => {
  if (!response.access_token) return undefined;
  try {
    const url = `https://api.trello.com/1/members/me?fields=username,fullName&key=${encodeURIComponent(
      response.key ?? ""
    )}&token=${encodeURIComponent(response.access_token)}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return undefined;
    const me = (await res.json()) as { id?: string; username?: string; fullName?: string };
    if (!me.id) return undefined;
    return { memberId: me.id, username: me.username ?? null, fullName: me.fullName ?? null };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Trello member", error as Error);
    return undefined;
  }
};
```

(e) Add the `trello` entry to `PROVIDER_CONFIGS` (after `airtable`, ~line 657):

```typescript
  trello: {
    name: "Trello",
    authMode: "token-fragment",
    authUrl: "https://trello.com/1/authorize",
    // No tokenUrl: Trello returns the token in the authorize fragment.
    requiresHttpsRedirect: true,
    parseTokenResponse: parseTrelloTokenResponse,
    extractMetadata: (providerData: ProviderData): Record<string, string> | undefined => {
      const t = providerData as TrelloProviderData;
      return t.memberId ? { memberId: t.memberId } : undefined;
    },
    extractAccountLabel: (d) =>
      (d as TrelloProviderData).fullName ?? (d as TrelloProviderData).username ?? null,
  },
```

(f) Add the `extractUserId` case (~line 457, alongside `github`/`linear`/`airtable` — but Trello's id field is `memberId`, so give it its own case):

```typescript
    case "trello" as AuthProvider:
      return (providerData as TrelloProviderData).memberId ?? null;
```

- [ ] **Step 4: Add env bindings + deploy var**

In `workers/api/src/env.ts` (after the `AUTH_AIRTABLE_*` lines, ~207):

```typescript
  readonly AUTH_TRELLO_ID: string;
  readonly AUTH_TRELLO_SECRET: string;
```

In `workers/api/package.json`, append to the `config.deploy_vars` string (before the closing quote):

```
 AUTH_TRELLO_ID AUTH_TRELLO_SECRET
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd workers/api && pnpm vitest run src/provider.trello.test.ts
```
Expected: PASS (all 7 assertions).

- [ ] **Step 6: Typecheck the package**

```bash
cd workers/api && pnpm exec tsc --noEmit
```
Expected: no errors (the `PROVIDER_CONFIGS` Record is now complete for `AuthProvider.Trello`).

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
git add workers/api/src/provider.ts workers/api/src/provider.trello.test.ts workers/api/src/env.ts workers/api/package.json
git commit -m "feat(api): Trello provider config, parse helper, env bindings"
```

---

### Task 3: `GenerateAuthUrl` token-fragment branch (`integrations.ts`)

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — `GenerateAuthUrl` (~5532-5583, after `authState` is stashed)
- Test: `workers/api/src/twist/tools/integrations.trello.test.ts` (new)

**Interfaces:**
- Consumes: `PROVIDER_CONFIGS.trello` (Task 2), `AuthState` (existing).
- Produces: for `authMode === "token-fragment"`, `GenerateAuthUrl` returns a Trello authorize URL: `https://trello.com/1/authorize?key=<clientId>&response_type=token&scope=read,write&expiration=never&name=Plot&return_url=<bridge>?state=<state>`.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/tools/integrations.trello.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";
import { Integrations } from "./integrations";

// Minimal Durable-Object storage stub: idFromName + get().set() on the stub.
function makeStorage() {
  const store = new Map<string, string>();
  const stub = {
    get: vi.fn(async (k: string) => store.get(k)),
    set: vi.fn(async (k: string, v: string) => void store.set(k, v)),
  };
  return {
    idFromName: vi.fn(() => "auth-id"),
    get: vi.fn(() => stub),
    _stub: stub,
  } as any;
}

function makeEnv() {
  return {
    API_ROOT: "https://api.plot.test",
    AUTH_TRELLO_ID: "trello-key-123",
    AUTH_TRELLO_SECRET: "trello-secret-456",
  } as any;
}

describe("GenerateAuthUrl — Trello token-fragment", () => {
  it("builds the Trello authorize URL with key, response_type=token and state in return_url", async () => {
    const result = await Integrations.GenerateAuthUrl({
      provider: "trello" as any,
      scopes: ["read", "write"],
      redirectUri: "plotday://auth",
      env: makeEnv(),
      storage: makeStorage(),
    });
    expect(result).not.toBeNull();
    const url = new URL(result!.url);
    expect(url.origin + url.pathname).toBe("https://trello.com/1/authorize");
    expect(url.searchParams.get("key")).toBe("trello-key-123");
    expect(url.searchParams.get("response_type")).toBe("token");
    expect(url.searchParams.get("scope")).toBe("read,write");
    expect(url.searchParams.get("expiration")).toBe("never");
    expect(url.searchParams.get("name")).toBe("Plot");
    // state is carried in return_url because Trello does not echo `state`.
    const returnUrl = new URL(url.searchParams.get("return_url")!);
    expect(returnUrl.origin + returnUrl.pathname).toBe("https://api.plot.test/auth/bridge");
    expect(returnUrl.searchParams.get("state")).toBe(result!.state);
    // No PKCE on a token-fragment flow.
    expect(url.searchParams.get("code_challenge")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "Trello token-fragment"
```
Expected: FAIL — the URL is built with `response_type=code` / `client_id`, not Trello's shape.

- [ ] **Step 3: Implement the branch**

In `GenerateAuthUrl`, immediately **after** the `authState` is written to storage (`await storageObj.set(state, superjson.stringify(authState));`, ~5544) and **before** the existing `response_type: "code"` URLSearchParams build, insert:

```typescript
// Token-fragment providers (Trello) are not OAuth 2.0: the token is returned
// in the authorize-redirect fragment, there is no code exchange, and `state`
// is not echoed — so we carry it in return_url. Build Trello's own param shape.
if (config.authMode === "token-fragment") {
  const returnUrl = `${effectiveRedirectUri}?state=${encodeURIComponent(state)}`;
  const trelloParams = new URLSearchParams({
    key: clientId,
    response_type: "token",
    scope: allScopes.join(","),
    expiration: "never",
    name: "Plot",
    return_url: returnUrl,
  });
  return { url: `${config.authUrl}?${trelloParams.toString()}`, clientId, state };
}
```

(`clientId` is already resolved above from `AUTH_TRELLO_ID`; `effectiveRedirectUri` is already the bridge because `requiresHttpsRedirect: true`.)

- [ ] **Step 4: Run test to verify it passes**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "Trello token-fragment"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations.trello.test.ts
git commit -m "feat(api): GenerateAuthUrl branch for Trello token-fragment flow"
```

---

### Task 4: `HandleOauthCallback` token-fragment branch (`integrations.ts`)

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — `HandleOauthCallback` (~5159-5180, replacing the `exchangeCodeForTokens` call with a branch)
- Test: `workers/api/src/twist/tools/integrations.trello.test.ts` (extend)

**Interfaces:**
- Consumes: relayed token in `params.token` (delivered by the bridge, Task 5); `PROVIDER_CONFIGS.trello.authMode`.
- Produces: for token-fragment providers, invokes the connector onAuth callback with `{ access_token: <relayed token>, key: env.AUTH_TRELLO_ID, provider: "trello", scopes }` — same `invokeWebhookCallback` path as OAuth.

- [ ] **Step 1: Write the failing test**

Append to `workers/api/src/twist/tools/integrations.trello.test.ts`:

```typescript
import * as callbacks from "../callbacks"; // adjust to the module exporting invokeWebhookCallback

describe("HandleOauthCallback — Trello token-fragment", () => {
  it("skips the code exchange and invokes onAuth with the relayed token", async () => {
    // Seed AuthState for the state token.
    const storage = makeStorage();
    const state = "state-trello-1";
    const authState = {
      provider: "trello",
      scopes: ["read", "write"],
      callback: { token: "cb-token" } as any,
      clientId: "trello-key-123",
    };
    // superjson is what the runtime uses; a plain JSON string also parses via its fallback.
    storage._stub.set(state, JSON.stringify({ json: authState }));

    // Trello /members/me fetch (called by parseTrelloTokenResponse in onAuth).
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ id: "member-1", username: "k", fullName: "K" }), { status: 200 }),
    );

    const invokeSpy = vi
      .spyOn(callbacks, "invokeWebhookCallback")
      .mockResolvedValue(undefined as any);

    const res = await Integrations.HandleOauthCallback(
      storage,
      { state, token: "user-token-abc" },
      makeEnv(),
      { exports: {} } as any,
    );

    expect(res.ok).toBe(true);
    expect(invokeSpy).toHaveBeenCalledTimes(1);
    const payload = invokeSpy.mock.calls[0][3] as any;
    expect(payload.access_token).toBe("user-token-abc");
    expect(payload.provider).toBe("trello");
    expect(payload.key).toBe("trello-key-123");
    expect(payload.scopes).toEqual(["read", "write"]);
  });
});
```

> Note: confirm the import path/module that actually exports `invokeWebhookCallback` (grep `export .*invokeWebhookCallback` under `workers/api/src`) and adjust the `vi.spyOn` target so the spy intercepts the same binding `HandleOauthCallback` calls.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "HandleOauthCallback — Trello"
```
Expected: FAIL — current code calls `exchangeCodeForTokens`, which throws `Token exchange not implemented for trello` (no `tokenUrl`).

- [ ] **Step 3: Implement the branch**

In `HandleOauthCallback`, replace the unconditional `exchangeCodeForTokens` call (~5171) with a branch. Locate:

```typescript
const tokenResponse = await Integrations.exchangeCodeForTokens({
  clientId,
  code,
  codeVerifier: authState.codeVerifier,
  provider: authState.provider,
  redirectUri,
  env,
});
```

Replace with:

```typescript
const providerConfig = PROVIDER_CONFIGS[authState.provider];
let tokenResponse: { access_token: string; [key: string]: any };
if (providerConfig?.authMode === "token-fragment") {
  // Trello: the token arrived in the authorize fragment and was relayed by the
  // bridge into params.token. No code exchange. Synthesize the token response
  // with the app key so parseTokenResponse can call the members API.
  const relayed = params.token;
  if (!relayed) {
    return new Response(JSON.stringify({ error: "Missing Trello token" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
  tokenResponse = { access_token: relayed, key: env.AUTH_TRELLO_ID };
} else {
  tokenResponse = await Integrations.exchangeCodeForTokens({
    clientId,
    code,
    codeVerifier: authState.codeVerifier,
    provider: authState.provider,
    redirectUri,
    env,
  });
}
```

> The `code` presence check earlier in `HandleOauthCallback` must not reject the token-fragment flow (which has `token`, not `code`). If that guard exists before this point, widen it: `if (!code && providerConfig?.authMode !== "token-fragment") { ...400... }`. Verify by reading the lines just above the exchange call.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "HandleOauthCallback — Trello"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations.trello.test.ts
git commit -m "feat(api): HandleOauthCallback uses relayed token for Trello"
```

---

### Task 5: Auth bridge — read the fragment, relay the token (`authBridge.ts`)

**Files:**
- Modify: `workers/api/src/app/authBridge.ts` — the `GET /auth/bridge` handler (~29-102) and a new `POST /auth/bridge` handler; a new `htmlFragmentCaptureResponse(...)` helper near `htmlBridgeResponse` (~460)
- Test: `workers/api/src/app/authBridge.trello.test.ts` (new)

**Interfaces:**
- Consumes: `PROVIDER_CONFIGS[provider].authMode`, `Integrations.HandleOauthCallback`.
- Produces:
  - GET, when the peeked provider is token-fragment and there is no `token` in the query yet → an HTML "capture" page that reads `location.hash`, extracts `token`, POSTs `{ state, token }` to `/auth/bridge`, then deep-links back to `bridgeUri`.
  - POST `/auth/bridge` → reads `{ state, token }` from the JSON body, calls `HandleOauthCallback(STORAGE, { state, token }, env, ctx)`, returns its `Response`.

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/app/authBridge.trello.test.ts`:

```typescript
import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import authBridgeRoutes from "./authBridge";
import { Integrations } from "../twist/tools/integrations";

function makeEnv(stateValue: object | null) {
  const stub = { get: vi.fn(async () => (stateValue ? JSON.stringify({ json: stateValue }) : null)) };
  return {
    STORAGE: { idFromName: vi.fn(() => "auth"), get: vi.fn(() => stub) },
    API_ROOT: "https://api.plot.test",
    SITE_ROOT: "https://plot.test",
  } as any;
}

function app() {
  const a = new Hono<{ Bindings: any }>();
  a.route("/", authBridgeRoutes);
  return a;
}

describe("auth bridge — Trello fragment capture", () => {
  it("GET renders a capture page that reads location.hash and POSTs the token", async () => {
    const env = makeEnv({ provider: "trello", bridgeUri: "plotday://auth" });
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge?state=st-1"),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("location.hash");
    expect(html).toContain("/auth/bridge"); // POST target
    expect(html).toContain("plotday://auth"); // deep-link back target
  });

  it("POST completes the callback with the relayed token", async () => {
    const env = makeEnv({ provider: "trello" });
    const spy = vi
      .spyOn(Integrations, "HandleOauthCallback")
      .mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }));
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state: "st-1", token: "user-token-abc" }),
      }),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(1);
    const params = spy.mock.calls[0][1] as Record<string, string>;
    expect(params.state).toBe("st-1");
    expect(params.token).toBe("user-token-abc");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm vitest run src/app/authBridge.trello.test.ts
```
Expected: FAIL — GET renders the generic page (no `location.hash` script); POST route doesn't exist (404).

- [ ] **Step 3: Implement the capture-page helper**

In `workers/api/src/app/authBridge.ts`, add near `htmlBridgeResponse` (~460):

```typescript
// Token-fragment providers (Trello) deliver the token in the URL fragment,
// which never reaches the server. This page reads it client-side and POSTs it
// back so HandleOauthCallback can complete, then deep-links to bridgeUri.
function htmlFragmentCaptureResponse({
  state,
  bridgeUri,
  apiRoot,
}: {
  state: string;
  bridgeUri: string | null;
  apiRoot: string;
}): Response {
  const cfg = JSON.stringify({ state, bridgeUri, post: `${apiRoot}/auth/bridge` });
  const body = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Finishing sign-in…</title>
<meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body><p>Finishing sign-in…</p>
<script>
  (function () {
    var cfg = ${cfg};
    var token = new URLSearchParams((location.hash || "").replace(/^#/, "")).get("token");
    function done(ok) {
      if (cfg.bridgeUri) {
        location.replace(cfg.bridgeUri + (cfg.bridgeUri.indexOf("?") < 0 ? "?" : "&") +
          "state=" + encodeURIComponent(cfg.state) + (ok ? "&success=1" : "&error=1"));
      }
    }
    if (!token) { done(false); return; }
    fetch(cfg.post, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ state: cfg.state, token: token }),
    }).then(function (r) { done(r.ok); }).catch(function () { done(false); });
  })();
</script></body></html>`;
  return new Response(body, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
}
```

- [ ] **Step 4: Branch the GET handler + add the POST handler**

At the top of `authBridge.ts`, ensure the import exists:

```typescript
import { PROVIDER_CONFIGS } from "../provider";
```

In the `GET /auth/bridge` handler, **after** the AuthState peek populates `provider`/`bridgeUri` and **before** the `installOnly`/error handling calls `HandleOauthCallback`, add:

```typescript
// Token-fragment providers: the token is in the fragment. If it hasn't been
// relayed yet (no ?token=), serve the capture page that reads it and POSTs back.
if (
  provider &&
  PROVIDER_CONFIGS[provider as AuthProvider]?.authMode === "token-fragment" &&
  !query.token &&
  !error
) {
  return htmlFragmentCaptureResponse({
    state: state ?? "",
    bridgeUri,
    apiRoot: c.env.API_ROOT,
  });
}
```

Add the POST route just after the GET handler:

```typescript
authBridgeRoutes.post("/auth/bridge", async (c) => {
  const { state, token } = await c.req.json<{ state?: string; token?: string }>();
  if (!state || !token) {
    return new Response(JSON.stringify({ error: "Missing state or token" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
  return Integrations.HandleOauthCallback(
    c.env.STORAGE,
    { state, token },
    c.env,
    c.executionCtx as unknown as { exports: ExecutionContext["exports"] },
  );
});
```

(Import `AuthProvider` if not already imported: `import { AuthProvider } from "@plotday/twister/tools/integrations";` — match the existing import style in the file.)

- [ ] **Step 5: Run test to verify it passes**

```bash
cd workers/api && pnpm vitest run src/app/authBridge.trello.test.ts
```
Expected: PASS (both cases).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/app/authBridge.ts workers/api/src/app/authBridge.trello.test.ts
git commit -m "feat(api): auth bridge relays Trello fragment token via POST"
```

---

### Task 6: Inject Trello app key+secret into `AuthToken` at `get()` (`integrations.ts`)

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — `get()` AuthToken construction, both sites (~566-572 main path and ~565-572 sub-connector fallback)
- Test: `workers/api/src/twist/tools/integrations.trello.test.ts` (extend)

**Interfaces:**
- Consumes: `env.AUTH_TRELLO_ID`, `env.AUTH_TRELLO_SECRET`.
- Produces: for `provider === "trello"`, the returned `AuthToken.provider` includes `key` and `secret` (read fresh from `env`, never persisted) in addition to `memberId`. The connector reads `token.provider.key` / `token.provider.secret` at sync time.

- [ ] **Step 1: Write the failing test**

Append to `workers/api/src/twist/tools/integrations.trello.test.ts`. This test constructs an `Integrations` whose stored token resolves for `provider "trello"`; assert `get()` returns the injected creds. Use the existing test's Store/DO seam — grep an existing `integrations` unit test for how `Integrations` is instantiated with a mocked `STORAGE`/`Store`, and mirror it. Skeleton:

```typescript
describe("get() — Trello app credential injection", () => {
  it("merges key+secret from env into AuthToken.provider for trello", async () => {
    // Arrange: an Integrations instance whose stored token for provider "trello"
    // has providerData { memberId }. (Mirror the seam used by existing
    // integrations.get unit tests — Store stub returning StoredTokenData.)
    const integrations = makeTrelloIntegrations({
      env: makeEnv(),
      stored: { access_token: "user-tok", scopes: ["read", "write"], providerData: { memberId: "m1", username: "u", fullName: "F" } },
    });

    const token = await integrations.get("board-1"); // channelId

    expect(token?.token).toBe("user-tok");
    expect(token?.provider?.memberId).toBe("m1");
    expect(token?.provider?.key).toBe("trello-key-123");
    expect(token?.provider?.secret).toBe("trello-secret-456");
  });
});
```

> If no existing `integrations.get` unit test exists to copy the `makeTrelloIntegrations` seam from, assert the injection logic on a small extracted pure helper instead (Step 3 defines `withTrelloAppCreds`): `expect(withTrelloAppCreds("trello" as any, { memberId: "m1" }, makeEnv())).toMatchObject({ memberId: "m1", key: "trello-key-123", secret: "trello-secret-456" })` and `expect(withTrelloAppCreds("linear" as any, { x: 1 }, makeEnv())).toEqual({ x: 1 })`. Prefer the helper test if the DO seam is heavy to stub.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "Trello app credential"
```
Expected: FAIL — `provider` metadata has only `memberId`, no `key`/`secret`.

- [ ] **Step 3: Implement a small helper + apply at both return sites**

Near the top of the `Integrations` class (or as a module-level function), add:

```typescript
// Trello's app key (non-secret) and app secret (server-only) are not part of the
// stored token — inject them from env at read time so the connector can sign
// requests/webhooks. Never persisted; read fresh on every get().
function withTrelloAppCreds(
  provider: AuthProvider,
  meta: Record<string, string> | undefined,
  env: Bindings,
): Record<string, string> | undefined {
  if (provider !== ("trello" as AuthProvider)) return meta;
  return { ...(meta ?? {}), key: env.AUTH_TRELLO_ID, secret: env.AUTH_TRELLO_SECRET };
}
```

At **both** AuthToken return sites in `get()`, wrap the `provider` field:

```typescript
return {
  token: tokenData.access_token,
  scopes: tokenData.scopes,
  provider: withTrelloAppCreds(
    provider,
    tokenData.providerData
      ? providerConfig?.extractMetadata?.(tokenData.providerData)
      : undefined,
    this.env,
  ),
};
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd workers/api && pnpm vitest run src/twist/tools/integrations.trello.test.ts -t "Trello app credential"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts workers/api/src/twist/tools/integrations.trello.test.ts
git commit -m "feat(api): inject Trello app key+secret into AuthToken at read time"
```

---

### Task 7: Finalize — full lint, typecheck, test sweep

**Files:** none new — verification + cleanup only.

- [ ] **Step 1: Run the new tests together**

```bash
cd workers/api && pnpm vitest run src/provider.trello.test.ts src/twist/tools/integrations.trello.test.ts src/app/authBridge.trello.test.ts
```
Expected: all PASS.

- [ ] **Step 2: Typecheck + lint the changed packages**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/workers/api && pnpm exec tsc --noEmit && pnpm lint
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector/public/twister && pnpm lint
```
Expected: no type errors, no lint errors. (Workers-api lint excludes test files per repo config — that's expected; the tsc step covers tests.)

- [ ] **Step 3: Confirm no broader breakage in the auth area**

```bash
cd workers/api && pnpm vitest run src/app/twist-integrations.test.ts src/twist/tools/auth-scope.test.ts
```
Expected: existing auth tests still PASS (the token-fragment branches are additive and gated on `authMode`).

- [ ] **Step 4: Commit any lint fixups**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/trello-connector
git add -A
git commit -m "chore(api): lint + typecheck fixups for Trello auth provider" --allow-empty
```

---

## Out of scope (handled elsewhere)

- **Provisioning** (Trello app key/secret → 1Password → `sync-github-secrets`) — human-gated; see spec §1.4. Until done, the flow can't be exercised end-to-end, only unit-tested.
- **`connections.ts` `available: true` flip** — belongs with the connector (Plan 2), so Trello doesn't surface as connectable before the connector exists.
- **The connector itself, checklists, structured-items foundation** — Plans 2–5.

## Self-Review

**Spec coverage (Part 1):**
- `AuthProvider.Trello` enum + changeset → Task 1. ✓
- `authMode: "token-fragment"`, `TrelloProviderData`, `parseTrello*`, `PROVIDER_CONFIGS.trello`, `extractUserId` → Task 2. ✓ (Refinement vs spec: parse reads `response.key` instead of needing `env`, keeping it on the standard `parseTokenResponse` path — documented in Task 2(d).)
- `GenerateAuthUrl` token-fragment branch → Task 3. ✓
- Bridge fragment read + relay → Task 5 (chosen mechanism: client reads `location.hash`, **POSTs** the token so it never lands in a server-logged query string — resolves the spec's "keep token out of logs" open item). ✓
- `HandleOauthCallback` token-fragment branch → Task 4. ✓
- `AuthToken` key+secret injection from `env` → Task 6. ✓
- `env.ts` Bindings + `deploy_vars` → Task 2 (Steps 4). ✓
- Security (token material never in Postgres / `user.*`; secret from env, not persisted) → preserved by Task 6's read-time injection; no persistence added. ✓

**Type consistency:** `TrelloProviderData` (memberId/username/fullName) is used identically in Tasks 2 and 6; `parseTrelloTokenResponse` signature matches `ProviderConfig.parseTokenResponse`; `authMode: "token-fragment"` is the same literal in Tasks 2–6; `withTrelloAppCreds` defined and used only in Task 6.

**Placeholder scan:** the two `> Note:` callouts (invoke-callback import path in Task 4; the `get()` test seam in Task 6) are verification instructions with concrete fallbacks, not unfilled placeholders — each has runnable code either way.
