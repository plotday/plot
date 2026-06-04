# Connection scope validation & legacy re-auth — design

**Date:** 2026-06-03
**Branch:** `fix/connection-scope-reauth`

## Problem

When a user authorizes an OAuth connection, Plot should confirm they granted
every required scope before activating it. If they unchecked a permission box,
show a friendly "try again and grant all permissions" message instead of
activating a connection that will silently fail.

This is **already implemented** for standard OAuth providers — commit
`a3e48f26a` (2026-05-22) added a scope-grant check in the OAuth callback
(`workers/api/src/twist/tools/integrations.ts:4160-4191`). It parses the scopes
the user actually granted, compares them against the requested scopes
(excluding email scopes), and returns a friendly message + refuses to run
`onAuth` if any required scope is missing.

Investigation surfaced two real gaps the existing check does not cover:

### Gap 1 — `parseGrantedScopes` is not provider-aware

`parseGrantedScopes` (`integrations.ts:4309`) reads only the top-level `scope`
field of the token response. Slack is configured as a user-token-only app
(`provider.ts:516-521`): it requests scopes via `user_scope` and returns the
granted scopes at `authed_user.scope`, **not** top-level `scope`. So for Slack
(and any future user-scope provider), `parseGrantedScopes` returns `null` and
the validation is **silently skipped** — a partial Slack grant would slip
through.

No production impact observed today (no Slack scope errors in PostHog), but it
is a latent correctness hole in exactly the validation we care about.

### Gap 2 — Legacy connections error every day forever

PostHog error issue `019e4fef-…` shows a Google Calendar connection whose token
is missing `calendar.calendarlist.readonly`. The daily channel-refresh sweep
(05:00 UTC) calls `calendar.v3.CalendarList.List`, gets
`HTTP 403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`, and re-throws it — captured to
PostHog — **once per day, every day** since 2026-05-22 (10 of 11 occurrences
fire at ~01:02 ET = the 05:00 UTC sweep; zero off-cycle occurrences, confirming
no *new* authorizations are slipping past the auth-time check).

This connection was authorized **before** the 2026-05-22 fix, so the auth-time
check never ran on it. Nothing flags it for re-auth and nothing stops the
sweep from retrying the doomed call daily. The user's calendar silently does
not sync and we accumulate daily error noise.

## Constraints / what already exists

- **`needs_reauth_at` pipeline exists end-to-end.** `flagNeedsReauth(provider,
  actorId)` (`integrations.ts:2193`) sets `twist_instance_connection.needs_reauth_at`
  + `recovery_pending` and fires a push via `notifyUserSyncByEnv()`. The
  `user.twist_connection` view exposes `needs_reauth`, and the Flutter app shows
  a "reconnect" banner. Successful re-auth (`onAuth`) clears the flag.
- **Permanent-failure classification pattern exists.** `classifyRefreshHttpError`
  + `PERMANENT_OAUTH_ERRORS` (`integrations.ts:153-196`) already distinguish
  permanent vs. transient token-refresh failures, calling `flagNeedsReauth` only
  on permanent ones. We mirror that philosophy ("unknown → transient").
- **Stored scopes are *requested*, not *granted*.** `onAuth` stores
  `scopes: tokenInfo.scopes` (`integrations.ts:2635`), where `tokenInfo.scopes`
  is `authState.scopes` — the requested set. So the legacy record falsely claims
  it has `calendarlist.readonly`. **A proactive stored-vs-required comparison
  cannot detect the legacy connection — detection on the sweep path must be
  reactive.**
- **The sweep builds, but does not execute, getChannels.** `refreshChannels`
  returns a `{ __dispatch }` descriptor; the 403 is thrown later inside the
  connector sandbox and surfaces at the sweep's `callCallback` catch
  (`refresh-channels.ts:74`). So flagging logic on this path must live at the
  sweep catch, not inside `refreshChannels`.
- **The RPC boundary flattens errors to a string — confirmed.** The connector
  fetches Google directly in its sandbox (`google-api.ts:136`), discarding the
  `Response` and throwing `Error("HTTP 403: {body}")`. `entrypoint.ts:698-720`
  then re-wraps *any* connector error as
  `new Error("__TWIST_ERROR__" + JSON.stringify({message, stack, name}))` —
  explicitly because custom properties / `error.cause` do not survive RPC. So on
  the sweep path a typed error buys nothing: the only signal that reaches the
  sweep catch is the `.message` string (the Google body, incl. the
  `ACCESS_TOKEN_SCOPE_INSUFFICIENT` marker, nested inside the `__TWIST_ERROR__`
  envelope). Detection parses that envelope, not a typed field.
- **The token-refresh path IS structured (no RPC boundary).** `refreshToken`
  (`integrations.ts:3952`) runs in the API worker and already produces
  `TokenRefreshError { status, oauthError, body }`, with `oauthError` parsed from
  the standard OAuth `error` field by `classifyRefreshHttpError` (`:167`). A 403
  at the *refresh endpoint* (OAuth `error: "insufficient_scope"`) can be
  classified structurally there, for all providers.
- **No schema change** (`needs_reauth_at` already exists). **No Flutter change**
  (banner already exists). **No Twister/public change** (no SDK surface touched).

## Design (chosen approach: "middle path")

Structured detection where the architecture allows it (the refresh path), and
string-parsing only where the RPC boundary leaves no alternative (the sweep
path). No change to stored-scope semantics.

### Fix A — Make `parseGrantedScopes` provider-aware

1. `workers/api/src/provider.ts`: add optional
   `extractGrantedScopes?: (response: any) => string | undefined` to
   `ProviderConfig` (parallels the existing `extractAccessToken`). Set it on the
   Slack config: `extractGrantedScopes: (r) => r?.authed_user?.scope`.
2. `integrations.ts`: change `parseGrantedScopes(tokenResponse)` →
   `parseGrantedScopes(tokenResponse, provider)`. Resolve the raw scope string as
   `config?.extractGrantedScopes?.(tokenResponse) ?? tokenResponse?.scope`, then
   split as today. Update the call site at `:4169` to pass `authState.provider`.

Default behavior (top-level `scope`) is unchanged for all other providers. The
change is internal to one file's static helper — no API contract change.

### Fix B — Flag legacy connections for re-auth instead of retrying

**B1 — Skip already-flagged connections (the noise-killer).**
Add `.where("tic.needs_reauth_at", "is", null)` to the sweep query
(`refresh-channels.ts:25-39`). Once a connection is flagged, it is never swept
again → no getChannels → no 403 → no daily capture. Re-auth clears
`needs_reauth_at`, so the sweep resumes automatically.

**B2 — Structured: classify `insufficient_scope` at the refresh endpoint (all
providers).**
Add `insufficient_scope` to `PERMANENT_OAUTH_ERRORS` (`integrations.ts:153`). A
403 at a provider's *token-refresh* endpoint then classifies as permanent and
routes through the **existing** `getActorToken` → `flagNeedsReauth` path
(`:2358`). This is a structured, standards-based, one-line change that works for
every provider, with no RPC-boundary or message-scraping concerns. (It does not
cover the legacy Google case on its own — that 403 comes from the API call, not
the refresh endpoint — but it closes the equivalent gap for refresh-endpoint
failures.)

**B3 — Reactive: flag on the API-call insufficient-scope 403 (sweep backstop).**
The legacy Google 403 comes from `getChannels`, not the refresh endpoint, and
arrives at the sweep catch only as a flattened `__TWIST_ERROR__` envelope. Add a
narrow public method on the `Integrations` tool —
`flagReauthIfInsufficientScope(provider, actorId, error)` — that unwraps the
`__TWIST_ERROR__` envelope, reads the inner `.message`, and calls the private
`flagNeedsReauth` only when the message carries the explicit
`ACCESS_TOKEN_SCOPE_INSUFFICIENT` / `insufficientPermissions` marker. The sweep's
catch block (`refresh-channels.ts:74`) delegates to it before logging.

Classification is **conservative**: flag **only** on the explicit marker. A
generic 403 (ACL, transient WAF, rate-limit) does **not** flag.

- False positive (wrongly flagging) would force a needless reconnect — avoided
  by requiring the explicit marker.
- False negative (not flagging an unrecognized error) just preserves today's
  behavior — no regression.

On the first sweep after deploy, the one broken connection hits its final 403,
gets flagged, the user is notified to reconnect, and it is skipped (B1) on every
sweep thereafter. No production DB surgery required.

## Rejected alternatives

- **Typed connector error (e.g. `InsufficientScopeError`) instead of string
  marker** — does not survive the RPC boundary. `entrypoint.ts:698-720` flattens
  every connector error to `.message`/`.stack`/`.name`, dropping custom
  properties and `error.cause`. On the sweep path the marker must live in the
  message regardless.
- **Broad / proactive: capture granted scopes on refresh + compare granted vs.
  required before any call** — the most reliable and widest-coverage option, but
  deferred. It changes `tokenData.scopes` from requested → granted, and that
  field feeds the `Authorization` handed to connectors, so a user declining an
  *optional* scope could shift connector behavior — a real blast radius. It is
  also provider-variable (Slack user tokens don't refresh like Google's). Not
  needed for the observed problem; revisit if under-scoping recurs across
  providers.
- **Proactive "stored scopes vs. required" check at sweep time (without the
  refresh-scope capture above)** — cannot work; stored scopes are the *requested*
  set, so the legacy record falsely claims it has the missing scope.
- **Detect inside the `entrypoint.ts` dispatch runtime** — rejected; that file is
  consumed as a template literal (all backticks must be escaped, edits are
  fragile), and the sweep catch already has `provider`/`actorId` in hand.

## Verification

- **Unit (workers/api):**
  - Fix A: `parseGrantedScopes` returns Slack scopes from `authed_user.scope`
    via `extractGrantedScopes`, and the top-level `scope` default is unchanged
    for other providers; the auth-time check rejects a partial Slack grant.
  - Fix B2: `classifyRefreshHttpError` returns `permanent: true` for a 403 body
    with OAuth `error: "insufficient_scope"`.
  - Fix B3: `flagReauthIfInsufficientScope` flags on a `__TWIST_ERROR__`
    envelope whose inner message contains `ACCESS_TOKEN_SCOPE_INSUFFICIENT`, and
    does **not** flag on a generic 403 / transient error / unrelated message.
- **Marker propagation is now confirmed** (RPC flattens to `.message`, marker
  nested inside the `__TWIST_ERROR__` envelope) — the B3 classifier must unwrap
  the envelope, not read the raw message. Add a test fixture matching the real
  envelope shape from `entrypoint.ts:698-720`.
- **Lint:** `pnpm --filter @plotday/api run lint` — no *new* `error TS`
  (`main` has 2 pre-existing).
- Gate as "no new errors" per the package's own `tsc`/`vitest`, not LSP
  diagnostics.

## Out of scope

- Backfilling / repairing the existing broken connection's stored data (it
  self-heals on the next sweep → flag → user reconnect).
- Switching stored scopes from requested to granted.
- Any change to the Flutter "reconnect" UI or notification copy.
