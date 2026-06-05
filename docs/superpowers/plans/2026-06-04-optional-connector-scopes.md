# Optional Connector Scopes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let connectors declare optional OAuth scopes that auth tolerates if declined, plus a friendly permissions description; apply it to Google Calendar (contacts + calendar-listing become optional).

**Architecture:** Most plumbing already exists (commit `a3e48f26a`). This finishes it: (1) two pure scope helpers in `auth-scope.ts`; (2) wire required-only grant validation + persist *granted* scopes in `integrations.ts`; (3) thread a `description` through the API factory + endpoint; (4) expose a `ScopeConfig` type in the Twister SDK; (5) restructure the Google Calendar connector + add a `getChannels` primary-only fallback; (6) render the required-permission bullets in Flutter.

**Tech Stack:** TypeScript (Cloudflare Workers, `workers/api`), Twister SDK (`public/twister`), Google Calendar connector (`public/connectors/google-calendar`), Flutter/Dart (`apps/plot`), vitest, Atlas (n/a — no schema changes).

**Spec:** `docs/superpowers/specs/2026-06-04-optional-connector-scopes-design.md`

**Worktree / submodule note:** Tasks 5 and 6 modify the `public/` submodule. In the worktree, create a submodule branch first (`cd public && git checkout -b feat/optional-connector-scopes`) and rebuild twister (`cd public/twister && pnpm build`) before building the connector or running API/Flutter against the new types. The core-repo commits for those tasks bump the submodule pointer.

**Pre-existing-error caveat:** `workers/api` `tsc` already reports 2 pre-existing errors on `main` (Uint8Array/BlobPart). The gate is "no NEW `error TS`", not exit 0. The vitest pool can wedge the shell on exit — prefer `pnpm exec vitest run <file>` (single file) over the full suite where possible.

---

## File structure

- `workers/api/src/twist/tools/auth-scope.ts` — add `OptionalScopeGroup` type + `resolveRequestedScopes` + `findMissingRequiredScopes` (pure, unit-tested).
- `workers/api/src/twist/tools/auth-scope.test.ts` — tests for the two new helpers.
- `workers/api/src/twist/tools/integrations.ts` — `AuthState.requiredScopes`; `GenerateAuthUrl` param; required-only validation via helper; persist granted scopes.
- `workers/api/src/twist/tools/factory.ts` — `ProviderDeclaration.description`; carry through `mergeProviderDeclarations`; reuse `OptionalScopeGroup`.
- `workers/api/src/twist/factory.ts` — read `description` off a structured `scopes` config.
- `workers/api/src/app/twist-integrations.ts` — POST `/auth` uses `resolveRequestedScopes` + passes `requiredScopes`; GET returns `description` (verify pass-through).
- `public/twister/src/connector.ts` — `ScopeConfig` / `OptionalScopeGroup` types; `Connector.scopes: string[] | ScopeConfig`.
- `public/.changeset/optional-connector-scopes.md` — changeset.
- `public/connectors/google-calendar/src/google-calendar.ts` — structured `scopes` + `getChannels` fallback.
- `apps/plot/lib/api/twist_api.dart` — `TwistProvider.description`.
- `apps/plot/lib/command/twist.dart` — render required bullets in `_AuthWithScopeToggles`.
- `docs/updates.md` — user-facing note.

---

## Task 1: Pure scope helpers (TDD)

**Files:**
- Modify: `workers/api/src/twist/tools/auth-scope.ts`
- Test: `workers/api/src/twist/tools/auth-scope.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `workers/api/src/twist/tools/auth-scope.test.ts`:

```ts
import {
  findMissingRequiredScopes,
  resolveRequestedScopes,
} from "./auth-scope";

describe("resolveRequestedScopes", () => {
  const optional = [
    { id: "contacts", label: "Contacts", scopes: ["s.contacts"], default: true },
    { id: "calendars", label: "Calendars", scopes: ["s.list"], default: true },
  ];

  it("returns required scopes when there are no optional groups", () => {
    expect(resolveRequestedScopes(["s.events"], undefined, undefined)).toEqual([
      "s.events",
    ]);
  });

  it("includes default-on groups when the client sends no selection", () => {
    expect(resolveRequestedScopes(["s.events"], optional, undefined)).toEqual([
      "s.events",
      "s.contacts",
      "s.list",
    ]);
  });

  it("includes only the groups the client explicitly enabled", () => {
    expect(
      resolveRequestedScopes(["s.events"], optional, ["calendars"])
    ).toEqual(["s.events", "s.list"]);
  });

  it("excludes all optional scopes when the client sends an empty selection", () => {
    expect(resolveRequestedScopes(["s.events"], optional, [])).toEqual([
      "s.events",
    ]);
  });

  it("deduplicates overlapping scopes", () => {
    const overlap = [
      { id: "a", label: "A", scopes: ["s.events", "s.a"], default: true },
    ];
    expect(resolveRequestedScopes(["s.events"], overlap, undefined)).toEqual([
      "s.events",
      "s.a",
    ]);
  });
});

describe("findMissingRequiredScopes", () => {
  it("returns required scopes the user did not grant", () => {
    expect(
      findMissingRequiredScopes(["s.events", "s.write"], ["s.events"])
    ).toEqual(["s.write"]);
  });

  it("returns [] when every required scope was granted", () => {
    expect(
      findMissingRequiredScopes(["s.events"], ["s.events", "s.extra"])
    ).toEqual([]);
  });

  it("ignores email/identity scopes the runtime always appends", () => {
    expect(
      findMissingRequiredScopes(["s.events", "openid"], ["s.events"], ["openid"])
    ).toEqual([]);
  });

  it("never flags optional scopes (they are not passed in requiredScopes)", () => {
    // contacts/list are optional → caller omits them from requiredScopes
    expect(findMissingRequiredScopes(["s.events"], ["s.events"])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: FAIL — `resolveRequestedScopes`/`findMissingRequiredScopes` not exported.

- [ ] **Step 3: Implement the helpers**

Append to `workers/api/src/twist/tools/auth-scope.ts`:

```ts
/** An optional scope group a connector declares, toggleable at connect time. */
export type OptionalScopeGroup = {
  id: string;
  label: string;
  description?: string;
  scopes: string[];
  default: boolean;
};

/**
 * The full set of scopes to REQUEST for an OAuth flow: the required scopes plus
 * every enabled optional group, deduplicated. A group is enabled when the client
 * sent an explicit `enabledScopeGroups` list containing its id, or — when the
 * client sent no list — when the group's `default` is true.
 */
export function resolveRequestedScopes(
  requiredScopes: string[],
  optionalGroups: OptionalScopeGroup[] | undefined,
  enabledScopeGroups: string[] | undefined
): string[] {
  const scopes = [...requiredScopes];
  if (optionalGroups) {
    for (const group of optionalGroups) {
      const isEnabled = enabledScopeGroups
        ? enabledScopeGroups.includes(group.id)
        : group.default;
      if (isEnabled) scopes.push(...group.scopes);
    }
  }
  return [...new Set(scopes)];
}

/**
 * The required scopes the user did NOT grant. `emailScopes` (identity scopes the
 * runtime always appends, e.g. openid/email/profile) are excluded from
 * enforcement. Optional scopes are never passed in `requiredScopes`, so declining
 * an optional scope never appears here. Returns [] when nothing required is
 * missing.
 */
export function findMissingRequiredScopes(
  requiredScopes: string[],
  grantedScopes: string[],
  emailScopes: string[] = []
): string[] {
  const email = new Set(emailScopes);
  const granted = new Set(grantedScopes);
  return requiredScopes.filter((s) => !email.has(s) && !granted.has(s));
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/auth-scope.ts workers/api/src/twist/tools/auth-scope.test.ts
git commit -m "feat(api): add pure scope-resolution + required-grant helpers"
```

---

## Task 2: ProviderDeclaration carries `description` + factory reads it

**Files:**
- Modify: `workers/api/src/twist/tools/factory.ts:327-384`
- Modify: `workers/api/src/twist/factory.ts:488-509`

- [ ] **Step 1: Add `description` to `ProviderDeclaration` and reuse `OptionalScopeGroup`**

In `workers/api/src/twist/tools/factory.ts`, replace the `ProviderDeclaration` type (currently lines 327-338):

```ts
import type { OptionalScopeGroup } from "./auth-scope";

export type ProviderDeclaration = {
  provider: string;
  scopes: string[];
  /** Friendly bullets describing the always-on (required) access. */
  description?: string[];
  /** Optional scope groups the user can toggle before OAuth. */
  optionalScopes?: OptionalScopeGroup[];
};
```

(Place the `import type` with the other imports at the top of the file.)

- [ ] **Step 2: Carry `description` through `mergeProviderDeclarations`**

In the same file, update `mergeProviderDeclarations` (currently lines 355-384) so the per-provider entry and output include `description` (first declaration with a description wins, matching the existing `optionalScopes` rule):

```ts
export function mergeProviderDeclarations(
  declarations: ProviderDeclaration[]
): ProviderDeclaration[] {
  const byProvider = new Map<string, {
    scopes: Set<string>;
    description?: string[];
    optionalScopes?: OptionalScopeGroup[];
  }>();

  for (const decl of declarations) {
    if (!byProvider.has(decl.provider)) {
      byProvider.set(decl.provider, { scopes: new Set() });
    }
    const entry = byProvider.get(decl.provider)!;
    for (const scope of decl.scopes) {
      entry.scopes.add(scope);
    }
    // First declaration with these wins (connector-level).
    if (decl.description && !entry.description) {
      entry.description = decl.description;
    }
    if (decl.optionalScopes && !entry.optionalScopes) {
      entry.optionalScopes = decl.optionalScopes;
    }
  }

  return Array.from(byProvider.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([provider, entry]) => ({
      provider,
      scopes: Array.from(entry.scopes).sort(),
      ...(entry.description ? { description: entry.description } : {}),
      ...(entry.optionalScopes ? { optionalScopes: entry.optionalScopes } : {}),
    }));
}
```

- [ ] **Step 3: Read `description` off the structured scope config in the source-metadata path**

In `workers/api/src/twist/factory.ts`, update the scope-resolution block (currently lines 491-508):

```ts
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const rawScopes: any = sourceProvider.scopes;
        let requiredScopes: string[];
        let optionalScopes: any[] | undefined;
        let scopeDescription: string[] | undefined;
        if (Array.isArray(rawScopes)) {
          requiredScopes = rawScopes;
        } else if (rawScopes?.required) {
          requiredScopes = rawScopes.required;
          optionalScopes = rawScopes.optional;
          scopeDescription = rawScopes.description;
        } else {
          requiredScopes = [];
        }
        allProviders.push({
          provider: sourceProvider.provider,
          scopes: requiredScopes,
          ...(optionalScopes ? { optionalScopes } : {}),
          ...(scopeDescription ? { description: scopeDescription } : {}),
        });
        // Normalize scopes to string[] so downstream consumers see a flat array
        sourceProvider = { ...sourceProvider, scopes: requiredScopes };
```

- [ ] **Step 4: Type-check (no NEW errors)**

Run: `cd workers/api && pnpm exec tsc --noEmit 2>&1 | grep -c "error TS"`
Expected: `2` (the two pre-existing errors only — no new ones). If higher, inspect with `pnpm exec tsc --noEmit 2>&1 | grep "error TS"` and fix new errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/factory.ts workers/api/src/twist/factory.ts
git commit -m "feat(api): thread scope-config description through provider declarations"
```

---

## Task 3: twist-integrations endpoint — resolve scopes via helper, pass requiredScopes, expose description

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts:582-620`

- [ ] **Step 1: Replace inline scope resolution with the helper and pass `requiredScopes`**

In `workers/api/src/app/twist-integrations.ts`, import the helper (with the other imports near the top):

```ts
import { resolveRequestedScopes } from "../twist/tools/auth-scope";
```

Replace the inline resolution + `GenerateAuthUrl` call (currently lines 582-620) with:

```ts
  // Resolve final scopes including enabled optional scope groups.
  const { enabledScopeGroups } = parseResult.data;
  const finalScopes = resolveRequestedScopes(
    providerDecl.scopes,
    providerDecl.optionalScopes,
    enabledScopeGroups
  );

  // Create a callback token pointing to the Integrations tool's onAuth method
  const callbacksId = c.env.CALLBACKS.idFromName(twistInstanceId);
  const callbacksStub = c.env.CALLBACKS.get(callbacksId);
  const callback = await callbacksStub.create({
    twistInstanceId,
    path: integrationsPathStr.split(":"),
    functionName: "onAuth",
    extraArgs: [],
  });

  // Generate the auth URL
  const result = await Integrations.GenerateAuthUrl({
    provider: provider as any,
    scopes: finalScopes,
    requiredScopes: providerDecl.scopes,
    enabledScopeGroups,
    callback: callback as any,
    redirectUri,
    platform,
    forceBridge,
    env: c.env,
    storage: c.env.STORAGE,
    accountHint,
  });
```

(The GET `/integrations` response already returns `providers: allProviders` verbatim — `description` rides along once `ProviderDeclaration` carries it, no change needed there.)

- [ ] **Step 2: Type-check (no NEW errors)**

Run: `cd workers/api && pnpm exec tsc --noEmit 2>&1 | grep "error TS" | grep -v "Uint8Array\|BlobPart"`
Expected: no output (the only remaining errors are the two pre-existing ones, filtered out). `GenerateAuthUrl`'s new `requiredScopes` param is added in Task 4 — if this step reports a `requiredScopes` error, that is expected and is resolved by Task 4; proceed and re-check at the end of Task 4.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/twist-integrations.ts
git commit -m "feat(api): resolve optional scopes via helper and pass requiredScopes"
```

---

## Task 4: integrations.ts — AuthState.requiredScopes, GenerateAuthUrl param, required-only validation, persist granted scopes

**Files:**
- Modify: `workers/api/src/twist/tools/integrations.ts` — `AuthState` type (95-115), `HandleOauthCallback` validation + onAuth payload (4244-4287), `GenerateAuthUrl` signature + authState (4439-4461, 4608-4618).

- [ ] **Step 1: Add `requiredScopes` to `AuthState`**

In `workers/api/src/twist/tools/integrations.ts`, add to the `AuthState` type (after `scopes: string[];`, ~line 97):

```ts
  /** The subset of `scopes` that must be granted; optional scopes are excluded.
   *  Absent for sign-in flows and legacy states → treat all of `scopes` as required. */
  requiredScopes?: string[];
```

- [ ] **Step 2: Import the helper**

Ensure `findMissingRequiredScopes` is imported alongside the existing `auth-scope` import (line 39):

```ts
import {
  findMissingRequiredScopes,
  isInsufficientScopeError,
  parseGrantedScopes,
} from "./auth-scope";
```

- [ ] **Step 3: Replace the grant validation with required-only enforcement**

Replace the validation block (currently lines 4244-4269) with:

```ts
      const grantedScopes = parseGrantedScopes(
        tokenResponse,
        PROVIDER_CONFIGS[authState.provider]
      );
      // Enforce only REQUIRED scopes. Optional scopes the user declined on the
      // consent screen are tolerated — the connector degrades gracefully.
      // Fallback to the full requested set when requiredScopes is absent
      // (sign-in flows, legacy in-flight states) to preserve strict behaviour.
      const enforcedScopes = authState.requiredScopes ?? authState.scopes;
      if (grantedScopes && enforcedScopes?.length) {
        const providerConfig = PROVIDER_CONFIGS[authState.provider];
        const missing = findMissingRequiredScopes(
          enforcedScopes,
          grantedScopes,
          providerConfig?.emailScopes ?? []
        );
        if (missing.length > 0) {
          const providerName = providerConfig?.name ?? authState.provider;
          return new Response(
            JSON.stringify({
              error: `${providerName} access wasn't fully granted. Please try again and grant the required permissions so Plot can sync.`,
            }),
            {
              status: 400,
              headers: { "Content-Type": "application/json" },
            }
          );
        }
      }
```

- [ ] **Step 4: Persist GRANTED scopes into the token**

In the same method, the onAuth callback payload (currently lines 4280-4287) passes `scopes: authState.scopes` (the requested set). Change it to persist what was actually granted, falling back to requested when the provider didn't echo `scope`:

```ts
          const result = await invokeWebhookCallback(
            env,
            ctx,
            authState.callback,
            {
              // Spread all token response fields (provider-specific fields included)
              ...tokenResponse,
              // Add our metadata. Persist GRANTED scopes so connectors can gate
              // optional features on what the user actually consented to.
              provider: authState.provider,
              scopes: grantedScopes ?? authState.scopes,
              client_id: clientId,
            }
          );
```

- [ ] **Step 5: Add `requiredScopes` to `GenerateAuthUrl` and store it in authState**

In `GenerateAuthUrl`, add `requiredScopes` to the destructured params and the typed signature (around lines 4439-4461):

```ts
  static async GenerateAuthUrl({
    provider,
    scopes,
    requiredScopes,
    callback,
    redirectUri,
    platform,
    forceBridge,
    env,
    storage,
    enabledScopeGroups,
    accountHint,
  }: {
    provider: AuthProvider;
    scopes: string[];
    requiredScopes?: string[];
    callback?: Callback;
    redirectUri: string;
    platform?: "ios" | "android" | "desktop";
    forceBridge?: boolean;
    env: Bindings;
    storage: DurableObjectNamespace<Storage>;
    enabledScopeGroups?: string[];
    accountHint?: string;
  }): Promise<{ url: string; clientId: string; state: string } | null> {
```

Then add it to the `authState` object (currently lines 4608-4618):

```ts
    const authState: AuthState = {
      provider,
      scopes: allScopes,
      requiredScopes,
      codeVerifier,
      timestamp: Date.now(),
      callback,
      enabledScopeGroups,
      clientId,
      redirectUri: effectiveRedirectUri,
      bridgeUri,
    };
```

- [ ] **Step 6: Type-check (no NEW errors)**

Run: `cd workers/api && pnpm exec tsc --noEmit 2>&1 | grep "error TS" | grep -v "Uint8Array\|BlobPart"`
Expected: no output.

- [ ] **Step 7: Run the existing integrations/scope unit tests**

Run: `cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add workers/api/src/twist/tools/integrations.ts
git commit -m "fix(api): enforce only required scopes at auth and persist granted scopes"
```

---

## Task 5: Twister SDK — ScopeConfig type + changeset

**Files:**
- Modify: `public/connectors/...` — none yet; SDK only.
- Modify: `public/twister/src/connector.ts:217-230`
- Create: `public/.changeset/optional-connector-scopes.md`

- [ ] **Step 1: Create a submodule branch (worktree only)**

```bash
cd public && git checkout -b feat/optional-connector-scopes && cd ..
```

- [ ] **Step 2: Add the `ScopeConfig` / `OptionalScopeGroup` types and widen `scopes`**

In `public/twister/src/connector.ts`, add the exported types just above the `Connector` class (near line 216), and change the `scopes` field (line 229):

```ts
/** An optional OAuth scope group the user can toggle at connect time. */
export type OptionalScopeGroup = {
  /** Stable id used to track the user's selection. */
  id: string;
  /** Value-forward switch label, e.g. "Add names to events using contacts". */
  label: string;
  /** Optional secondary line shown under the label. */
  description?: string;
  /** The OAuth scope strings this group grants. */
  scopes: string[];
  /** Whether the group is requested by default (switch on). */
  default: boolean;
};

/**
 * Structured scope declaration. `required` scopes must be granted — auth fails
 * and re-prompts if any is declined. `optional` groups are requested by default
 * but auth still succeeds if the user declines them; the connector should detect
 * the absence via the granted `token.scopes` and degrade gracefully.
 */
export type ScopeConfig = {
  required: string[];
  /** Friendly bullets describing what the always-on (required) access does. */
  description?: string[];
  optional?: OptionalScopeGroup[];
};
```

Change the `scopes` declaration (line 229) from:

```ts
  /** OAuth scopes to request for this connector. */
  readonly scopes?: string[];
```

to:

```ts
  /** OAuth scopes to request for this connector — a flat list (all required), or
   *  a {@link ScopeConfig} declaring required + optional scope groups. */
  readonly scopes?: string[] | ScopeConfig;
```

- [ ] **Step 3: Create the changeset**

Create `public/.changeset/optional-connector-scopes.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `ScopeConfig` for a connector's `scopes` — declare `required` scopes, an optional `description` (friendly permission bullets shown at connect time), and `optional` scope groups the user can toggle. Auth now succeeds even when optional scopes are declined; connectors detect the result via the granted `token.scopes`.
```

- [ ] **Step 4: Build twister and validate the changeset**

```bash
cd public/twister && pnpm build && cd ../..
cd public && pnpm validate-changesets && cd ..
```
Expected: twister builds cleanly; changeset validation passes.

- [ ] **Step 5: Refresh the workspace link**

```bash
pnpm install
```

- [ ] **Step 6: Commit (submodule, then pointer)**

```bash
cd public && git add twister/src/connector.ts .changeset/optional-connector-scopes.md && \
  git commit -m "feat(twister): add ScopeConfig for optional connector scopes" && cd ..
git add public && git commit -m "chore: bump public submodule for ScopeConfig"
```

---

## Task 6: Google Calendar connector — structured scopes + getChannels fallback

**Files:**
- Modify: `public/connectors/google-calendar/src/google-calendar.ts:148-225`

- [ ] **Step 1: Replace the flat scopes with a structured `ScopeConfig`**

In `public/connectors/google-calendar/src/google-calendar.ts`, replace the static `SCOPES` + `readonly scopes` (currently lines 150-159) with:

```ts
  static readonly EVENTS_SCOPE =
    "https://www.googleapis.com/auth/calendar.events";
  static readonly CALENDAR_LIST_SCOPE =
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly";

  readonly provider = AuthProvider.Google;
  readonly scopes = {
    required: [GoogleCalendar.EVENTS_SCOPE],
    description: [
      "Reads your events to add them to your agenda",
      "Writes your event RSVPs",
    ],
    optional: [
      {
        id: "contacts",
        label: "Add names to events using contacts",
        scopes: GoogleContacts.SCOPES,
        default: true,
      },
      {
        id: "calendars",
        label: "List all calendars",
        description:
          "List all calendars so you can choose which to sync. If disabled, only your primary calendar will be synced.",
        scopes: [GoogleCalendar.CALENDAR_LIST_SCOPE],
        default: true,
      },
    ],
  };
```

Delete the now-unused `readonly provider = AuthProvider.Google;` duplicate if present (keep exactly one). The `Integrations.MergeScopes` call is removed; leave the `Integrations` and `GoogleContacts` imports (both still used by `build()` / enrichment).

- [ ] **Step 2: Add the primary-only fallback in `getChannels`**

Replace `getChannels` (currently lines 208-225) with:

```ts
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    // Listing the user's calendars needs the (optional) calendar-list scope.
    // If the user didn't grant it, sync only the primary calendar — calling
    // calendarList without the scope 403s and would wrongly flag the
    // connection for re-auth.
    if (!token.scopes.includes(GoogleCalendar.CALENDAR_LIST_SCOPE)) {
      return [{ id: "primary", title: "Calendar", enabledByDefault: true }];
    }
    const api = new GoogleApi(token.token);
    const calendars = await this.listCalendarsWithApi(api);
    // Default to syncing the user's OWN calendars (their primary + any
    // secondary calendars they created — accessRole "owner"). Calendars the
    // user merely subscribes to or that are shared with them are
    // "reader"/"writer"; exclude those from the default selection. The user
    // can still enable any of them manually.
    return calendars.map((c) => ({
      id: c.id,
      title: c.name,
      enabledByDefault: c.accessRole === "owner",
    }));
  }
```

- [ ] **Step 3: Build the connector**

```bash
cd public/connectors/google-calendar && pnpm exec tsc --noEmit && cd ../../..
```
Expected: no type errors (the structured `scopes` matches `ScopeConfig` from the rebuilt twister).

- [ ] **Step 4: Commit (submodule, then pointer)**

```bash
cd public && git add connectors/google-calendar/src/google-calendar.ts && \
  git commit -m "feat(google-calendar): make contacts and calendar-listing scopes optional" && cd ..
git add public && git commit -m "chore: bump public submodule for google-calendar optional scopes"
```

---

## Task 7: Flutter — provider description + render permission bullets

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart:803-829`
- Modify: `apps/plot/lib/command/twist.dart:3636-3700`

- [ ] **Step 1: Add `description` to `TwistProvider`**

In `apps/plot/lib/api/twist_api.dart`, replace the `TwistProvider` class (lines 803-829):

```dart
class TwistProvider extends Equatable {
  final AuthProvider provider;
  final List<String> scopes;

  /// Friendly bullets describing the always-on (required) permissions.
  final List<String> description;
  final List<OptionalScopeGroup>? optionalScopes;

  const TwistProvider({
    required this.provider,
    required this.scopes,
    this.description = const [],
    this.optionalScopes,
  });

  factory TwistProvider.fromJson(Map<String, dynamic> json) {
    return TwistProvider(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      description:
          (json['description'] as List<dynamic>?)?.cast<String>() ?? const [],
      optionalScopes: (json['optionalScopes'] as List<dynamic>?)
          ?.map((g) => OptionalScopeGroup.fromJson(g as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  List<Object?> get props => [provider, scopes, description, optionalScopes];
}
```

- [ ] **Step 2: Render the required bullets above the optional toggles**

In `apps/plot/lib/command/twist.dart`, in `_AuthWithScopeTogglesState.build` (line 3637), insert the description bullets as the first children of the `Column` (before the `if (optionalScopes != null && optionalScopes.isNotEmpty)` block at line 3643):

```dart
    final optionalScopes = widget.provider.optionalScopes;
    final description = widget.provider.description;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (description.isNotEmpty) ...[
          for (final line in description)
            Padding(
              padding: EdgeInsets.only(bottom: context.theme.spacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: context.theme.typography.sm.copyWith(
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: context.theme.spacing.sm),
        ],
        if (optionalScopes != null && optionalScopes.isNotEmpty) ...[
```

(The rest of the existing widget body — the optional toggle rows and the `AuthButton.connect` — is unchanged.)

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/api/twist_api.dart lib/command/twist.dart`
Expected: No errors (info-level lints tolerated; CI uses `--no-fatal-infos`).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/api/twist_api.dart apps/plot/lib/command/twist.dart
git commit -m "feat(app): show required-permission bullets above connector auth"
```

---

## Task 8: Finalize

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing update note**

Add to the top section of `docs/updates.md`:

```markdown
- When connecting Google Calendar, you can now see a short summary of what Plot accesses, and choose whether to share contacts (to add names to events) and list all your calendars. Skipping the optional permissions no longer blocks the connection — Plot just syncs your primary calendar.
```

- [ ] **Step 2: Run lint/type checks across changed packages**

```bash
cd workers/api && pnpm exec tsc --noEmit 2>&1 | grep "error TS" | grep -v "Uint8Array\|BlobPart"   # expect no output
cd ../.. && cd public/twister && pnpm build && cd ../..                                              # expect clean build
cd public/connectors/google-calendar && pnpm exec tsc --noEmit && cd ../../..                        # expect no errors
cd apps/plot && flutter analyze lib/api/twist_api.dart lib/command/twist.dart && cd ../..            # expect no errors
cd workers/api && pnpm exec vitest run src/twist/tools/auth-scope.test.ts && cd ../..                # expect PASS
```

- [ ] **Step 3: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs: note optional Google Calendar permissions"
```

- [ ] **Step 4: Runtime verification (manual)**

Use the `run-app` skill to connect Google Calendar: confirm the permissions bullets render above the connect button, both optional switches default on, declining contacts/calendars on Google's screen still completes the connection, and a connection without the calendar-list scope syncs only the primary calendar. Note: the `run-app` agent profile may not have a real Google account to complete OAuth — verify the UI render at minimum and flag if full OAuth couldn't be exercised.

- [ ] **Step 5: PRs**

Open a `public/` submodule PR (`feat/optional-connector-scopes`) for the twister + connector changes (changeset included), and the core PR (bumps the submodule pointer). Per `/finalize`, ensure the changeset is present and `docs/updates.md` is updated.

---

## Self-review

**Spec coverage:**
- "Optional scopes, auth succeeds if declined" → Task 4 (required-only validation) + Task 1 helper.
- "Persist granted scopes / gate features" → Task 4 (persist granted) + Task 6 (`getChannels` gate).
- "SDK support" → Task 5 (`ScopeConfig`) + Task 2/3 (runtime + endpoint).
- "Permission descriptions" → Task 2 (`description` through declarations), Task 7 (render), Task 6 (GCal copy).
- "Google Calendar contacts + listing optional" → Task 6.
- "Backwards compatibility (flat string[])" → Task 1 (`resolveRequestedScopes` returns required when no optional), Task 4 (`requiredScopes ?? scopes` fallback).
- Testing → Task 1 (unit), Task 8 (cross-package + runtime).

**Placeholder scan:** None — every code step has full code; every command has expected output.

**Type consistency:** `OptionalScopeGroup` is defined once in `auth-scope.ts` and reused by `ProviderDeclaration` (Task 2); the SDK's `OptionalScopeGroup`/`ScopeConfig` (Task 5) are structurally identical (id/label/description?/scopes/default; required/description?/optional). `resolveRequestedScopes`/`findMissingRequiredScopes` signatures match their call sites in Tasks 3 and 4. `GenerateAuthUrl`'s new `requiredScopes?` param (Task 4) matches the call in Task 3. `TwistProvider.description` (Task 7) matches the JSON key `description` emitted by `ProviderDeclaration` (Task 2).
