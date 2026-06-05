# Optional connector scopes + permission descriptions

**Date:** 2026-06-04
**Status:** Design (pending review)

## Goal

Add first-class support for **optional OAuth scopes** on connectors:

- **Required** scopes must be granted. If the user declines one, auth fails and
  re-prompts (current behaviour, but corrected to apply only to required scopes).
- **Optional** scopes are requested by default but **auth still succeeds if the
  user declines them**; the feature that needs the scope degrades gracefully.

Also surface a brief, friendly **description of the permissions** (required and
optional) next to the connect button so users understand what they're granting.

First application: **Google Calendar** — contacts (attendee name enrichment) and
calendar listing (sync calendars beyond the primary) become optional.

## Background — current state

A prior commit (`a3e48f26a` "Better handling when user doesn't grant
permissions") already built most of the plumbing:

- **API runtime** reads a structured `{ required, optional }` scope shape off a
  connector (`workers/api/src/twist/factory.ts:494-501`), threads `optionalScopes`
  through `ProviderDeclaration`, and resolves the final OAuth scope set from the
  client's `enabledScopeGroups` (`workers/api/src/app/twist-integrations.ts:583-596`).
- **Flutter** has `OptionalScopeGroup` (`apps/plot/lib/api/twist_api.dart:669`)
  and a `_AuthWithScopeToggles` widget (`apps/plot/lib/command/twist.dart:3605`)
  that renders a switch + label + description per optional group and passes
  `enabledScopeGroups` to the auth endpoint.

Four gaps remain:

1. **Not exposed in the SDK.** `Connector.scopes` is typed `string[]` only
   (`public/twister/src/connector.ts:229`). The runtime reads `.required`/
   `.optional` defensively, but no connector can declare them type-safely, and
   **none do** — Google Calendar still uses a flat `MergeScopes(...)`.
2. **"Optional not granted ⇒ still success" is actually broken.** The
   token-grant validation (`workers/api/src/twist/tools/integrations.ts:4248-4268`)
   treats *every* requested non-email scope as required — if any is missing it
   hard-fails with *"leave all permission boxes checked."* So declining an
   optional scope on Google's consent screen **fails** the whole auth.
3. **Stored token scopes are the *requested* set, not the *granted* set**
   (`integrations.ts:2663`), so a connector can't reliably tell which optional
   features it may use.
4. **No metadata describing the required permissions** for display.

This work **finishes and corrects** the existing feature rather than building
from scratch.

## Design

### 1. Scope config (Twister SDK)

`Connector.scopes` becomes `string[] | ScopeConfig`:

```ts
type ScopeConfig = {
  /** Hard scopes — always requested; auth fails (re-prompt) if any is denied. */
  required: string[];
  /** Friendly bullets describing the always-on (required) access. */
  description?: string[];
  /** Soft scope groups — requested by default, auth still succeeds if denied. */
  optional?: OptionalScopeGroup[];
};

type OptionalScopeGroup = {
  id: string;
  /** Value-forward switch label, e.g. "Add names to events using contacts". */
  label: string;
  /** Optional secondary line shown under the label. */
  description?: string;
  scopes: string[];
  /** Whether the group is requested by default (switch on). */
  default: boolean;
};
```

Two categories only:

| Category | In OAuth request? | UI | If denied |
|---|---|---|---|
| **Required** | always | description bullet(s) | **fail + re-prompt** |
| **Optional** | when its switch is on (default on) | switch w/ value label (+ description) | **succeed**, disable that feature |

The `OptionalScopeGroup` shape already matches the runtime's
`ProviderDeclaration.optionalScopes`; the only genuinely new field is the
top-level `description: string[]` for the required permissions.

The flat `string[]` form stays fully supported (treated as all-required).

### 2. Denial behaviour — the correctness fixes

**a. Validation scoped to required.** `authState` gains a `requiredScopes`
field (= the connector's `required`). The token-grant check
(`integrations.ts:4248`) fails only when a **required** scope is missing.
Optional denials pass. `GenerateAuthUrl` accepts `requiredScopes`; when absent
(sign-in flows, providers without the new config) it defaults to the full
requested set, preserving today's strict behaviour. Flat-`string[]` connectors
pass `requiredScopes = all`, so their behaviour is unchanged.

**b. Persist granted scopes.** At `onAuth`, store the parsed granted scopes
(`grantedScopes ?? requested` — the fallback covers providers that don't echo
`scope`) into `StoredTokenData.scopes` instead of the requested set. The refresh
path already preserves stored scopes (`integrations.ts:2359`), so granted scopes
survive refresh even when Google omits `scope` on refresh. Now
`integrations.get().scopes` reflects what was actually granted, and connectors
can gate optional features on it.

Re-auth flagging on `main` is error-driven (`isInsufficientScopeError`), not
based on comparing stored vs. declared scopes, so switching stored scopes from
requested → granted is safe.

### 3. Google Calendar connector

```ts
readonly scopes: ScopeConfig = {
  required: ["https://www.googleapis.com/auth/calendar.events"],
  description: [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ],
  optional: [
    {
      id: "contacts",
      label: "Add names to events using contacts",
      scopes: GoogleContacts.SCOPES, // contacts.readonly, contacts.other.readonly
      default: true,
    },
    {
      id: "calendars",
      label: "List all calendars",
      description:
        "List all calendars so you can choose which to sync. If disabled, only your primary calendar will be synced.",
      scopes: ["https://www.googleapis.com/auth/calendar.calendarlist.readonly"],
      default: true,
    },
  ],
};
```

- **`getChannels()`** checks granted scopes first: if
  `calendar.calendarlist.readonly` is not granted (user turned the switch off,
  or unchecked it on Google's screen), return only the `primary` channel instead
  of calling `/users/me/calendarList` — which would 403 and wrongly flag the
  connection for re-auth.
- **Contacts enrichment** already gates on `token.scopes`
  (`enrichLinkContactsFromGoogle`); once granted scopes are persisted, that gate
  is finally correct (today it sees the requested set, which always includes
  contacts).

### 4. UI — permissions block above the connect button

`_AuthWithScopeToggles` (`apps/plot/lib/command/twist.dart:3605`) is extended to
render the required `description` bullets above the existing optional switches:

```
Plot will:
 • Reads your events to add them to your agenda
 • Writes your event RSVPs
 ──────
 [✓] Add names to events using contacts
 [✓] List all calendars
     List all calendars so you can choose which to sync. If disabled,
     only your primary calendar will be synced.
 [ Connect Google Calendar ]
```

The optional switches (label + description) already render today; the new piece
is the required `description` bullet list.

### 5. Files touched

- **Twister SDK** (`public/` submodule):
  - `public/twister/src/connector.ts` — `Connector.scopes: string[] | ScopeConfig`;
    export `ScopeConfig` / `OptionalScopeGroup`.
  - **Changeset** at `public/.changeset/*.md` (`minor` — new feature) + submodule PR.
- **API** (`workers/api/src/`):
  - `twist/factory.ts` — read `description` off the scope config; pass it through.
  - `twist/tools/factory.ts` — add `description?: string[]` to `ProviderDeclaration`;
    carry it through `mergeProviderDeclarations`.
  - `app/twist-integrations.ts` — return `description` from `GET /integrations`;
    pass `requiredScopes` (= `providerDecl.scopes`) into `GenerateAuthUrl`.
  - `twist/tools/integrations.ts` — `GenerateAuthUrl`/`AuthState` carry
    `requiredScopes`; required-only validation; persist granted scopes at `onAuth`.
- **Flutter** (`apps/plot/lib/`):
  - `api/twist_api.dart` — add `TwistProvider.description: List<String>`.
  - `command/twist.dart` — render the required `description` bullets in
    `_AuthWithScopeToggles`.
- **Google Calendar connector** (`public/connectors/google-calendar/`):
  - `src/google-calendar.ts` — structured `scopes` config; `getChannels`
    primary-only fallback when listing scope absent.

### 6. Backwards compatibility

- Existing connections already granted every scope and keep working — changes
  only affect new connects / re-auths.
- Flat `string[]` scopes remain fully supported.
- No database or schema changes.

### 7. Testing

- **API unit tests**: scope resolution (optional on/off → correct OAuth scope
  set); required-only validation (optional denied ⇒ success; required denied ⇒
  400); granted-scope persistence (stored scopes = granted, survive refresh).
- **Connector test**: `getChannels` returns primary-only when
  `calendar.calendarlist.readonly` is absent from granted scopes; lists all when
  present.
- **Flutter**: `flutter analyze`; widget smoke for the permissions block.

## Out of scope / follow-ups

- **Incremental authorization** (request required first, optional in a separate
  step) — a possible future enhancement if real-world optional grant-rates are
  low; not in v1.
- **Converting other connectors** (Gmail, Slack, etc.) to optional scopes —
  the SDK support is general, but only Google Calendar is converted here.

## Risks

- **Submodule coordination**: Twister type change requires a changeset, a
  `pnpm build` of twister, and a separate `public/` PR; the core PR bumps the
  submodule pointer.
- **Granted-scope persistence**: confirm during implementation that no other
  `main` code path reads stored token scopes assuming they are the *requested*
  set (re-auth flagging confirmed error-driven; double-check connectors and any
  scope-comparison logic).
