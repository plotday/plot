# Connection Scope Validation & Legacy Re-auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the provider-aware scope-validation gap at OAuth authorization time, and stop legacy under-scoped connections from erroring on every daily sweep by flagging them for re-auth instead.

**Architecture:** Three changes in the API worker. (A) Make granted-scope parsing provider-aware so Slack-style `user_scope` grants are validated at auth time. (B1) The daily channel-refresh sweep skips connections already flagged `needs_reauth`. (B2) A 403 at a provider's token-refresh endpoint with OAuth `error: "insufficient_scope"` classifies as a permanent failure (routes through the existing `getActorToken → flagNeedsReauth` path). (B3) A 403 from a connector's API call carrying Google's `ACCESS_TOKEN_SCOPE_INSUFFICIENT` marker — which reaches the sweep only as a flattened `__TWIST_ERROR__` string — flags the connection for re-auth. Pure logic is extracted to a new dependency-free `auth-scope.ts` so it is unit-testable without importing the `integrations.ts` monolith.

**Tech Stack:** TypeScript, Cloudflare Workers, Kysely (Postgres), Vitest. No schema change, no Flutter change, no Twister/public change.

**Spec:** `docs/superpowers/specs/2026-06-03-connection-scope-reauth-design.md`

**Concurrency note:** Another session has untracked files in this working tree. Use **path-scoped** `git add <file> ...` in every commit — never `git add -A` / `git add .`.

---

## File Structure

- **Create** `workers/api/src/twist/tools/auth-scope.ts` — dependency-free pure helpers: `parseGrantedScopes`, `isInsufficientScopeError`. (Mirrors the existing small-module + co-located-test pattern of `validation.ts`/`validation.test.ts`.)
- **Create** `workers/api/src/twist/tools/auth-scope.test.ts` — unit tests for the above.
- **Modify** `workers/api/src/provider.ts` — add `extractGrantedScopes?` to `ProviderConfig` (~line 432) and set it on the Slack config (~line 527).
- **Modify** `workers/api/src/twist/tools/integrations.ts` — import `parseGrantedScopes`/`isInsufficientScopeError` from `auth-scope.ts`; remove the old `static parseGrantedScopes` (~line 4350); update its call site (~line 4210) to pass the provider config; add `"insufficient_scope"` to `PERMANENT_OAUTH_ERRORS` (~line 154); add a public `flagReauthIfInsufficientScope` method.
- **Modify** `workers/api/src/scheduled/refresh-channels.ts` — add a `needs_reauth_at IS NULL` filter to the sweep query (~line 36) and, in the catch block (~line 74), delegate to `flagReauthIfInsufficientScope`.

---

## Task 1: Pure granted-scope parser (Fix A logic)

**Files:**
- Create: `workers/api/src/twist/tools/auth-scope.ts`
- Test: `workers/api/src/twist/tools/auth-scope.test.ts`

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/tools/auth-scope.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { parseGrantedScopes } from "./auth-scope";

describe("parseGrantedScopes", () => {
  it("reads the top-level `scope` field by default (Google/Microsoft)", () => {
    const resp = { access_token: "x", scope: "openid email https://cal/events" };
    expect(parseGrantedScopes(resp)).toEqual([
      "openid",
      "email",
      "https://cal/events",
    ]);
  });

  it("returns null when no scope field is present", () => {
    expect(parseGrantedScopes({ access_token: "x" })).toBeNull();
    expect(parseGrantedScopes({ scope: "" })).toBeNull();
    expect(parseGrantedScopes({ scope: "   " })).toBeNull();
  });

  it("uses extractGrantedScopes when provided (Slack user_scope)", () => {
    const resp = {
      access_token: "bot",
      scope: "bot:scope",
      authed_user: { id: "U1", access_token: "user", scope: "users:read chat:write" },
    };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toEqual(["users:read", "chat:write"]);
  });

  it("falls back to top-level scope when extractGrantedScopes returns undefined", () => {
    const resp = { scope: "a b" };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toEqual(["a", "b"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: FAIL — cannot resolve `./auth-scope` (module does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `workers/api/src/twist/tools/auth-scope.ts`:

```ts
/**
 * Pure, dependency-free helpers for OAuth scope handling. Kept out of the
 * integrations.ts monolith so they can be unit-tested in isolation.
 */

/**
 * Extract the scopes the user actually granted from an OAuth token exchange
 * response. OAuth 2.0 defines `scope` as a space-separated string of granted
 * scopes (RFC 6749 §3.3); when present, it reflects the user's actual consent —
 * including any scopes they unchecked on a granular consent screen (Google,
 * Microsoft).
 *
 * Some providers return the granted scopes somewhere other than the top-level
 * `scope` field — e.g. Slack user-token-only apps return them at
 * `authed_user.scope`. Pass the provider config's `extractGrantedScopes` to
 * read from the right place.
 *
 * Returns null when no scope string is present, so callers can skip enforcement
 * instead of treating absence as "everything missing".
 */
export function parseGrantedScopes(
  tokenResponse: any,
  config?: { extractGrantedScopes?: (response: any) => string | undefined }
): string[] | null {
  const raw = config?.extractGrantedScopes?.(tokenResponse) ?? tokenResponse?.scope;
  if (typeof raw === "string" && raw.trim().length > 0) {
    return raw.split(/\s+/).filter(Boolean);
  }
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/auth-scope.ts workers/api/src/twist/tools/auth-scope.test.ts
git commit -m "feat(api): provider-aware parseGrantedScopes helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Insufficient-scope error classifier (Fix B3 logic)

**Files:**
- Modify: `workers/api/src/twist/tools/auth-scope.ts`
- Test: `workers/api/src/twist/tools/auth-scope.test.ts`

Background: a connector's API 403 reaches the sweep only as a flattened error.
`entrypoint.ts:707` re-wraps connector errors as
`new Error("__TWIST_ERROR__" + JSON.stringify({ message, twistStack, originalError }))`.
So the Google body (carrying `ACCESS_TOKEN_SCOPE_INSUFFICIENT`) is nested inside
`.message` as the envelope's inner `message`. The classifier must unwrap that
envelope (same approach as `error-handling.ts:101-111`).

- [ ] **Step 1: Write the failing test**

Append to `workers/api/src/twist/tools/auth-scope.test.ts`:

```ts
import { isInsufficientScopeError } from "./auth-scope";

describe("isInsufficientScopeError", () => {
  const googleBody = JSON.stringify({
    error: {
      code: 403,
      message: "Request had insufficient authentication scopes.",
      status: "PERMISSION_DENIED",
      details: [{ reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }],
    },
  });

  it("matches the marker inside a __TWIST_ERROR__ envelope", () => {
    const envelope =
      "__TWIST_ERROR__" +
      JSON.stringify({
        message: `HTTP 403: ${googleBody}`,
        twistStack: "...",
        originalError: "Error",
      });
    expect(isInsufficientScopeError(envelope)).toBe(true);
  });

  it("matches a raw (un-enveloped) message carrying the marker", () => {
    expect(isInsufficientScopeError(`HTTP 403: ${googleBody}`)).toBe(true);
  });

  it("matches the insufficientPermissions marker", () => {
    expect(
      isInsufficientScopeError('HTTP 403: {"reason":"insufficientPermissions"}')
    ).toBe(true);
  });

  it("does NOT match a generic 403 or transient error", () => {
    expect(isInsufficientScopeError("HTTP 403: Forbidden")).toBe(false);
    expect(isInsufficientScopeError("HTTP 429: rate limited")).toBe(false);
    expect(isInsufficientScopeError("network timeout")).toBe(false);
  });

  it("does not throw on a malformed __TWIST_ERROR__ envelope", () => {
    expect(isInsufficientScopeError("__TWIST_ERROR__not-json")).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: FAIL — `isInsufficientScopeError` is not exported.

- [ ] **Step 3: Write minimal implementation**

Append to `workers/api/src/twist/tools/auth-scope.ts`:

```ts
const TWIST_ERROR_MARKER = "__TWIST_ERROR__";

// Google's two signals that an access token is missing a required scope. Both
// are specific enough that a match means the token itself is under-scoped — not
// a transient 403 (ACL, WAF, rate-limit), which we deliberately do NOT flag.
const INSUFFICIENT_SCOPE_MARKERS = [
  "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
  "insufficientPermissions",
];

/**
 * True when an error thrown by a connector API call means the stored token is
 * permanently missing a required scope (user must re-authorize).
 *
 * Connector errors cross the twist RPC boundary flattened to a string: the
 * runtime re-wraps them as `__TWIST_ERROR__{json}` where the inner `message`
 * holds the original error text (entrypoint.ts). We unwrap that envelope (same
 * approach as error-handling.ts) before checking for the scope markers.
 */
export function isInsufficientScopeError(rawErrorMessage: string): boolean {
  let message = rawErrorMessage;
  const markerIndex = message.indexOf(TWIST_ERROR_MARKER);
  if (markerIndex !== -1) {
    try {
      const decoded = JSON.parse(
        message.slice(markerIndex + TWIST_ERROR_MARKER.length)
      );
      if (typeof decoded?.message === "string") {
        message = decoded.message;
      }
    } catch {
      // Malformed envelope — fall through and test the raw string.
    }
  }
  return INSUFFICIENT_SCOPE_MARKERS.some((m) => message.includes(m));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: PASS (all `parseGrantedScopes` + `isInsufficientScopeError` tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/auth-scope.ts workers/api/src/twist/tools/auth-scope.test.ts
git commit -m "feat(api): isInsufficientScopeError classifier for connector 403s

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire Fix A — provider-aware validation at auth time

**Files:**
- Modify: `workers/api/src/provider.ts` (~line 432 type, ~line 527 Slack config)
- Modify: `workers/api/src/twist/tools/integrations.ts` (import; call site ~line 4210; remove old static ~line 4350)

- [ ] **Step 1: Add `extractGrantedScopes` to the `ProviderConfig` type**

In `workers/api/src/provider.ts`, immediately after the `extractAccessToken?` field (currently ~line 432):

```ts
  extractAccessToken?: (response: any) => string | undefined;
  // Pick the granted-scope string from the token-exchange response when it
  // isn't at the default top-level `scope`. Slack user-token-only apps return
  // the user's granted scopes at `authed_user.scope`. Used by auth-time scope
  // validation (parseGrantedScopes) so a partial grant is detected per-provider.
  extractGrantedScopes?: (response: any) => string | undefined;
```

- [ ] **Step 2: Set `extractGrantedScopes` on the Slack config**

In `workers/api/src/provider.ts`, in the `slack:` config block, right after the existing `extractAccessToken:` line (~line 527):

```ts
    extractAccessToken: (r) => r?.authed_user?.access_token ?? r?.access_token,
    // Slack returns the user's granted scopes at `authed_user.scope` (top-level
    // `scope` carries bot scopes). Without this, auth-time validation reads the
    // wrong field and silently skips the granted-vs-required check.
    extractGrantedScopes: (r) => r?.authed_user?.scope,
```

- [ ] **Step 3: Import the helper and update the call site in integrations.ts**

In `workers/api/src/twist/tools/integrations.ts`, add to the existing imports near the top of the file (with the other local `./` or `../` imports). Import only `parseGrantedScopes` for now — `isInsufficientScopeError` is added to this same import in Task 5 (importing it before its first use would trip an unused-import lint error at the end of this task):

```ts
import { parseGrantedScopes } from "./auth-scope";
```

Then change the scope-grant verification call site (currently ~line 4210):

```ts
      const grantedScopes = Integrations.parseGrantedScopes(tokenResponse);
```

to:

```ts
      const grantedScopes = parseGrantedScopes(
        tokenResponse,
        PROVIDER_CONFIGS[authState.provider]
      );
```

(`PROVIDER_CONFIGS` is already imported in this file — it is used a few lines below at the `providerConfig` lookup.)

- [ ] **Step 4: Remove the now-unused static `parseGrantedScopes`**

In `workers/api/src/twist/tools/integrations.ts`, delete the entire `static parseGrantedScopes(...)` method and its doc comment (currently ~line 4339-4357, the block beginning with the `/** Extract the scopes the user actually granted ... */` comment and ending at the method's closing `}`). Its only caller was updated in Step 3.

- [ ] **Step 5: Typecheck**

Run: `cd workers/api && pnpm lint`
Expected: no *new* `error TS` lines (the `main` baseline has 2 pre-existing Uint8Array/BlobPart errors — those are allowed; anything else referencing `auth-scope`, `parseGrantedScopes`, or `extractGrantedScopes` must be clean).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/provider.ts workers/api/src/twist/tools/integrations.ts
git commit -m "fix(api): validate Slack user_scope grants at auth time

parseGrantedScopes now reads granted scopes per-provider via
ProviderConfig.extractGrantedScopes, closing the gap where Slack
partial grants (authed_user.scope) silently skipped validation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire Fix B2 — classify refresh-endpoint insufficient_scope as permanent

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (~line 154)

- [ ] **Step 1: Add `insufficient_scope` to `PERMANENT_OAUTH_ERRORS`**

In `workers/api/src/twist/tools/integrations.ts`, the set currently (~line 154) reads:

```ts
const PERMANENT_OAUTH_ERRORS = new Set([
  "invalid_grant",
  "invalid_client",
  "unauthorized_client",
  "invalid_request",
  "unsupported_grant_type",
]);
```

Change it to add `insufficient_scope`:

```ts
const PERMANENT_OAUTH_ERRORS = new Set([
  "invalid_grant",
  "invalid_client",
  "unauthorized_client",
  "invalid_request",
  "unsupported_grant_type",
  // A token-refresh response of `insufficient_scope` means the stored grant is
  // missing a required scope and cannot be refreshed into a working token —
  // the user must re-authorize. Routes through getActorToken → flagNeedsReauth.
  "insufficient_scope",
]);
```

This requires no other change: `classifyRefreshHttpError` already parses the
OAuth `error` field and treats anything in this set as permanent, and
`getActorToken` already calls `flagNeedsReauth` on permanent refresh failures.

- [ ] **Step 2: Typecheck**

Run: `cd workers/api && pnpm lint`
Expected: no new `error TS`.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "fix(api): treat OAuth insufficient_scope refresh failure as permanent

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire Fix B3 — public method to flag re-auth on insufficient-scope API 403

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` (add method after `markNeedsReauth`, ~line 2266)

- [ ] **Step 1: Add the `flagReauthIfInsufficientScope` method**

In `workers/api/src/twist/tools/integrations.ts`, immediately after the `markNeedsReauth(channelId)` method (closing `}` ~line 2266), add:

```ts
  /**
   * Sweep-time re-auth signal. The daily channel-refresh sweep calls a
   * connector's getChannels via the stored token; if the token is missing a
   * required scope the provider returns a 403 (e.g. Google
   * ACCESS_TOKEN_SCOPE_INSUFFICIENT). That error reaches the sweep only as a
   * flattened `__TWIST_ERROR__` string, so we classify it here and flag the
   * connection for re-auth. Returns true when it flagged.
   *
   * Conservative by design: only the explicit insufficient-scope markers flag.
   * A generic 403 (ACL, transient WAF) is left alone — a false positive would
   * force a needless reconnect.
   */
  async flagReauthIfInsufficientScope(
    provider: AuthProvider,
    actorId: ActorId,
    rawErrorMessage: string
  ): Promise<boolean> {
    if (!isInsufficientScopeError(rawErrorMessage)) return false;
    await this.flagNeedsReauth(provider, actorId);
    return true;
  }
```

This method first uses `isInsufficientScopeError`. Update the Task 3 import to add it:

```ts
import { isInsufficientScopeError, parseGrantedScopes } from "./auth-scope";
```

- [ ] **Step 2: Typecheck**

Run: `cd workers/api && pnpm lint`
Expected: no new `error TS`.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "feat(api): Integrations.flagReauthIfInsufficientScope for sweep 403s

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire Fix B1 + B3 into the daily sweep

**Files:**
- Modify: `workers/api/src/scheduled/refresh-channels.ts`

- [ ] **Step 1: Skip connections already flagged for re-auth (B1)**

In `workers/api/src/scheduled/refresh-channels.ts`, the query (currently ~lines 36-39) ends with:

```ts
      .where("ti.archived_at", "is", null)
      .where("ti.suspended_at", "is", null)
      .where("ti.draft", "=", false)
      .execute();
```

Add a `needs_reauth_at` filter so flagged connections are never re-swept (this is what stops the daily error noise — once flagged, no getChannels call → no repeat 403):

```ts
      .where("ti.archived_at", "is", null)
      .where("ti.suspended_at", "is", null)
      .where("ti.draft", "=", false)
      // Skip connections already awaiting re-auth: re-running getChannels would
      // just re-hit the same auth failure (and re-capture it) every day. The
      // flag clears automatically when the user re-authorizes (onAuth), so the
      // sweep resumes then.
      .where("tic.needs_reauth_at", "is", null)
      .execute();
```

- [ ] **Step 2: Flag insufficient-scope failures in the catch block (B3)**

In `workers/api/src/scheduled/refresh-channels.ts`, the loop body declares
`integrationsPath` inside the `try`. Hoist it so the `catch` can reuse it, then
delegate to `flagReauthIfInsufficientScope` on failure.

Replace the loop body (currently ~lines 47-82) with:

```ts
    for (const row of rows) {
      let integrationsPath: string | undefined;
      try {
        const configJson = await env.TWIST_CONFIG.get(
          `${row.twistPackageId}:${row.version}`
        );
        if (!configJson) {
          skipped++;
          continue;
        }
        const parsed = JSON.parse(configJson) as {
          integrationsMap?: Record<string, string>;
        };
        integrationsPath = parsed.integrationsMap?.[row.provider];
        if (!integrationsPath) {
          skipped++;
          continue;
        }

        const wrapper = await factory({ twistInstanceId: row.twistInstanceId });
        const result = await wrapper.callCallback(
          integrationsPath.split(":"),
          "refreshChannels",
          row.provider,
          row.actorId
        );
        disposeRpc(result);
        success++;
      } catch (error) {
        failed++;
        const message = (error as Error).message;
        // If the failure is a missing-scope 403, flag the connection for
        // re-auth (and stop sweeping it — see the needs_reauth_at filter above)
        // instead of re-capturing the same error every day.
        if (integrationsPath) {
          try {
            const wrapper = await factory({
              twistInstanceId: row.twistInstanceId,
            });
            const flagResult = await wrapper.callCallback(
              integrationsPath.split(":"),
              "flagReauthIfInsufficientScope",
              row.provider,
              row.actorId,
              message
            );
            disposeRpc(flagResult);
          } catch (flagError) {
            logger.warn("Failed to flag needs_reauth after refresh failure", {
              error: (flagError as Error).message,
              twist_instance_id: row.twistInstanceId,
              provider: row.provider,
              actor_id: row.actorId,
            });
          }
        }
        logger.warn("Periodic channel refresh failed for connection", {
          error: message,
          twist_instance_id: row.twistInstanceId,
          provider: row.provider,
          actor_id: row.actorId,
        });
      }
    }
```

- [ ] **Step 3: Typecheck**

Run: `cd workers/api && pnpm lint`
Expected: no new `error TS`.

- [ ] **Step 4: Run the full unit suite to confirm nothing regressed**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: PASS. (The sweep wiring itself is exercised by typecheck + the
unit-tested `isInsufficientScopeError` it delegates to; it has no isolated unit
test because it requires the DB + twist factory.)

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/scheduled/refresh-channels.ts
git commit -m "fix(api): flag + skip under-scoped connections in daily refresh sweep

Connections missing a required scope (e.g. a Google Calendar token without
calendarlist.readonly authorized before the auth-time check existed) get
flagged needs_reauth on their next 403 and are then skipped, instead of
re-hitting and re-capturing the same error every day.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Finalize

**Files:**
- Modify: `docs/updates.md`
- (run finalization checks)

- [ ] **Step 1: Add a user-facing update note**

At the top section of `docs/updates.md`, add a bullet in plain language:

```markdown
- When a connected account (like a calendar) is missing a permission Plot needs, we'll now prompt you to reconnect it instead of silently failing to sync.
```

- [ ] **Step 2: Run the finalize checklist**

Invoke the `/finalize` skill (or run its steps): lint the changed package, confirm
backwards compatibility (no removed/renamed API fields — `parseGrantedScopes`
was an internal static with a single in-repo caller; `extractGrantedScopes` is
additive), and confirm error capture (the new catch path logs via `logger.warn`
and does not swallow unexpected errors — the existing capture behavior is
unchanged; no new `captureException` needed because these are handled/expected
auth failures).

Run: `cd workers/api && pnpm lint`
Expected: no new `error TS`.

- [ ] **Step 3: Commit**

```bash
git add docs/updates.md
git commit -m "docs: note reconnect prompt for under-scoped connections

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Fix A → Tasks 1, 3. Fix B1 → Task 6 Step 1. Fix B2 → Task 4. Fix B3 → Tasks 2, 5, 6 Step 2. Verification → Tasks 1, 2 (unit) + per-task lint.
- **No public-submodule change**, no schema change, no changeset required.
- **The `parseGrantedScopes` rename of caller arg:** the old static took only `tokenResponse`; the new free function takes `(tokenResponse, config?)`. The single caller (auth callback) now passes `PROVIDER_CONFIGS[authState.provider]`. Confirm via `grep -rn "parseGrantedScopes" workers/api/src` that no other caller remains after Task 3 Step 4.
- **Do not** switch stored `tokenData.scopes` from requested → granted — explicitly out of scope (see spec "Rejected alternatives").
