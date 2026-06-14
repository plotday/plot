# Connector Access Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a connector-level `access?: string[]` field (plain-language "what you're granting" bullets) shown on every connect screen — OAuth, credential, and Unipile — replacing the OAuth-only `ScopeConfig.description`, and populate it for all connectors.

**Architecture:** One SDK field `Connector.access` flows through two existing data paths to two connect-screen variants: (A) provider-based connectors (OAuth + Unipile) via `getSourceMetadata` → `ProviderDeclaration` → `TwistProvider.access`; (B) credential connectors via the no-provider route response → `TwistIntegrations.access`. The wire dual-emits `description` for back-compat with old native clients. Each connector declares its own `readonly access = [...]`.

**Tech Stack:** TypeScript (Twister SDK in `public/twister`, Cloudflare Workers API in `workers/api`), Dart/Flutter (`apps/plot`), pnpm workspaces, Changesets.

**Spec:** `docs/superpowers/specs/2026-06-14-connector-access-copy-design.md`

**Working directory:** worktree `/Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy` (branch `connector-access-copy`; public submodule on branch `feat/connector-access-copy`).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `public/twister/src/connector.ts` | SDK type defs | Add `Connector.access`; remove `ScopeConfig.description` |
| `public/.changeset/connector-access.md` | Changeset | New (minor) |
| `public/connectors/*/src/*.ts` | 15 public connectors | Add `readonly access` (gcal also drops `description`) |
| `connectors/{linkedin,instagram,whatsapp}/src/*.ts` | 3 private connectors | Add `readonly access` |
| `workers/api/src/twist/entrypoint.ts` | `getSourceMetadata` | Pass `access` through |
| `workers/api/src/twist/factory.ts` | sourceProvider + scope resolution | Read `access`, push to declaration |
| `workers/api/src/twist/tools/factory.ts` | `ProviderDeclaration` + merge | Rename `description`→`access` |
| `workers/api/src/twist/tools/integrations.ts` | `getIntegrationData` | Dual-emit `access` + `description` |
| `workers/api/src/app/twist-integrations.ts` | GET /integrations route | Copy `access`; add to no-provider branches |
| `apps/plot/lib/api/twist_api.dart` | `TwistProvider`, `TwistIntegrations` | Add `access` |
| `apps/plot/lib/command/twist.dart` | connect screens | Render `access` (both variants) |
| `docs/updates.md` | user-facing changelog | New bullet |

---

## Task 1: Twister SDK — add `Connector.access`, remove `ScopeConfig.description`

**Files:**
- Modify: `public/twister/src/connector.ts` (ScopeConfig ~196-201, Connector field ~260-262)
- Create: `public/.changeset/connector-access.md`

- [ ] **Step 1: Remove `description` from `ScopeConfig`**

In `public/twister/src/connector.ts`, replace the current `ScopeConfig` (lines ~196-201):

```typescript
export type ScopeConfig = {
  required: string[];
  /** Friendly bullets describing what the always-on (required) access does. */
  description?: string[];
  optional?: OptionalScopeGroup[];
};
```

with:

```typescript
export type ScopeConfig = {
  required: string[];
  optional?: OptionalScopeGroup[];
};
```

- [ ] **Step 2: Add `access` to the `Connector` base class**

Immediately after the `readonly scopes?: string[] | ScopeConfig;` declaration (~line 262), insert:

```typescript

  /**
   * Plain-language bullets describing what access connecting this service
   * grants the user — shown on the connect screen regardless of auth mechanism
   * (OAuth, API key, or hosted). For OAuth connectors it also previews what the
   * provider's consent screen will request. These are justifications for what
   * Plot accesses, not a one-to-one mapping of scope strings.
   */
  readonly access?: string[];
```

- [ ] **Step 3: Create the changeset**

Create `public/.changeset/connector-access.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `Connector.access` — plain-language bullets describing what access connecting a service grants, shown on every connect screen regardless of auth mechanism. Removed: `ScopeConfig.description` (declare `Connector.access` on the connector instead).
```

- [ ] **Step 4: Rebuild twister and validate the changeset**

Run:
```bash
cd public/twister && pnpm build
cd .. && pnpm validate-changesets
```
Expected: build prints `Found 0 errors`; validate-changesets passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/public
git add src/connector.ts .changeset/connector-access.md
git commit -m "feat(twister): add Connector.access, remove ScopeConfig.description"
```

---

## Task 2: Public connectors — declare `access`

Add `readonly access = [...]` to each connector class, on the line directly after its `readonly scopes = ...;` declaration. For **google-calendar**, additionally remove the now-invalid `description:` key from its `scopes` object.

**Files (all under `public/connectors/`):**
- Modify: `google-calendar/src/google-calendar.ts`, `slack/src/slack.ts`, `gmail/src/gmail.ts`, `google-drive/src/google-drive.ts`, `google-chat/src/google-chat.ts`, `google-tasks/src/google-tasks.ts`, `outlook-mail/src/outlook-mail.ts`, `outlook-calendar/src/outlook-calendar.ts`, `ms-teams/src/ms-teams.ts`, `linear/src/linear.ts`, `jira/src/jira.ts`, `asana/src/asana.ts`, `todoist/src/todoist.ts`, `airtable/src/airtable.ts`, `github/src/github.ts`, `attio/src/attio.ts`, `apple-calendar/src/apple-calendar.ts`, `fellow/src/fellow.ts`, `granola/src/granola.ts`, `posthog/src/posthog.ts`

- [ ] **Step 1: google-calendar — drop `description`, add `access`**

In `google-calendar/src/google-calendar.ts`, remove these lines from the `scopes` object (~160-163):
```typescript
    description: [
      "Reads your events to add them to your agenda",
      "Writes your event RSVPs",
    ],
```
Then add, directly after the closing `};` of the `scopes` object (after ~line 180):
```typescript
  readonly access = [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ];
```

- [ ] **Step 2: slack — add `access` (ScopeConfig unchanged)**

After `readonly scopes = Slack.SCOPES;` in `slack/src/slack.ts`:
```typescript
  readonly access = [
    "Reads messages in the channels and DMs you sync",
    "Sends messages and replies you write in Plot",
    "Adds and removes emoji reactions you make in Plot",
  ];
```

- [ ] **Step 3: Add `access` to the remaining 13 OAuth connectors**

After each connector's `readonly scopes = ...;` line, add the matching block:

`gmail/src/gmail.ts`:
```typescript
  readonly access = [
    "Reads your email so Plot can turn messages into threads and tasks",
    "Sends replies, creates drafts, and updates labels and read state from Plot",
    "Reads your contacts to recognise senders by name and photo",
  ];
```

`google-drive/src/google-drive.ts`:
```typescript
  readonly access = [
    "Reads your files to bring documents into Plot",
    "Adds the comments and replies you write in Plot. Google has no comments-only permission, so Plot must request full Drive access — but commenting is the only change it makes",
    "Reads your contacts to show who shared or commented",
  ];
```

`google-chat/src/google-chat.ts`:
```typescript
  readonly access = [
    "Reads messages in the spaces you sync",
    "Sends messages and replies you write in Plot, and can start new spaces",
    "Reads your contacts to show who's in each conversation",
  ];
```

`google-tasks/src/google-tasks.ts`:
```typescript
  readonly access = [
    "Reads and updates your Google Tasks so they stay in sync with Plot",
    "Creates and completes tasks you change in Plot",
  ];
```

`outlook-mail/src/outlook-mail.ts`:
```typescript
  readonly access = [
    "Reads your email so Plot can turn messages into threads and tasks",
    "Sends replies, creates drafts, and updates messages from Plot",
    "Reads your contacts to recognise senders by name",
  ];
```

`outlook-calendar/src/outlook-calendar.ts`:
```typescript
  readonly access = [
    "Reads your events to add them to your agenda",
    "Writes your event RSVPs",
  ];
```

`ms-teams/src/ms-teams.ts`:
```typescript
  readonly access = [
    "Reads your Teams channels and chats to bring conversations into Plot",
    "Sends messages and replies you write in Plot, and can start new chats",
    "Reads your team and user profiles to show who's who",
  ];
```

`linear/src/linear.ts`:
```typescript
  readonly access = [
    "Reads your issues, projects, and comments",
    "Creates and updates issues and posts comments you make in Plot",
    "Keeps Plot up to date as issues change in Linear",
  ];
```

`jira/src/jira.ts`:
```typescript
  readonly access = [
    "Reads your issues, projects, and users",
    "Creates and updates issues and posts comments you make in Plot",
    "Keeps Plot up to date as issues change in Jira",
  ];
```

`asana/src/asana.ts`:
```typescript
  readonly access = [
    "Reads your tasks, projects, and comments",
    "Creates and updates tasks and posts comments you make in Plot",
    "Keeps Plot up to date as tasks change in Asana",
  ];
```

`todoist/src/todoist.ts`:
```typescript
  readonly access = [
    "Reads and updates your tasks and projects so they stay in sync with Plot",
    "Creates and completes tasks you change in Plot",
  ];
```

`airtable/src/airtable.ts`:
```typescript
  readonly access = [
    "Reads your bases and their records",
    "Updates records you change in Plot",
    "Keeps Plot up to date as records change in Airtable",
  ];
```

`github/src/github.ts`:
```typescript
  readonly access = [
    "Reads your repositories' issues and pull requests",
    "Posts comments and updates you make in Plot",
    "Keeps Plot up to date as issues and pull requests change in GitHub",
  ];
```

- [ ] **Step 4: Add `access` to the 5 credential connectors**

`attio/src/attio.ts` (add after the class's `provider`/`keyOption`/`shared` identity fields, near the top of the class body):
```typescript
  readonly access = [
    "Reads your records — people, companies, and deals",
    "Updates records and adds notes you make in Plot",
  ];
```

`apple-calendar/src/apple-calendar.ts`:
```typescript
  readonly access = [
    "Reads your iCloud calendar events to add them to your agenda",
    "Writes your event RSVPs",
  ];
```

`fellow/src/fellow.ts`:
```typescript
  readonly access = [
    "Reads your meeting notes to attach them to the right events in Plot",
  ];
```

`granola/src/granola.ts`:
```typescript
  readonly access = [
    "Reads your meeting notes and transcripts to attach them to the right events in Plot",
  ];
```

`posthog/src/posthog.ts`:
```typescript
  readonly access = [
    "Reads the people from the project you connect",
  ];
```

> Credential connectors have no `readonly scopes` line; place `access` alongside the other class-level `readonly` identity fields (e.g. after `keyOption`/`shared`). Exact line varies per file — put it with the other top-of-class field declarations.

- [ ] **Step 5: Typecheck the changed connectors**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
for c in google-calendar slack gmail google-drive google-chat google-tasks outlook-mail outlook-calendar ms-teams linear jira asana todoist airtable github attio apple-calendar fellow granola posthog; do
  echo "== $c =="; (cd public/connectors/$c && pnpm exec tsc --noEmit) || echo "FAIL $c";
done
```
Expected: every connector compiles with no errors (no `FAIL` lines).

- [ ] **Step 6: Commit (public submodule)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/public
git add connectors
git commit -m "feat(connectors): declare access copy on all public connectors"
```

---

## Task 3: Private connectors — declare `access`

**Files (under `connectors/` in the core repo, NOT the submodule):**
- Modify: `connectors/linkedin/src/linkedin.ts`, `connectors/instagram/src/instagram.ts`, `connectors/whatsapp/src/whatsapp.ts`

- [ ] **Step 1: Add `access` after each `readonly scopes = ...;` line**

`connectors/linkedin/src/linkedin.ts`:
```typescript
  readonly access = [
    "Reads your LinkedIn messages and conversations",
    "Sends messages and replies you write in Plot",
  ];
```

`connectors/instagram/src/instagram.ts`:
```typescript
  readonly access = [
    "Reads your Instagram direct messages",
    "Sends replies you write in Plot",
  ];
```

`connectors/whatsapp/src/whatsapp.ts`:
```typescript
  readonly access = [
    "Reads your WhatsApp messages",
    "Sends replies you write in Plot",
  ];
```

- [ ] **Step 2: Typecheck**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
for c in linkedin instagram whatsapp; do echo "== $c =="; (cd connectors/$c && pnpm exec tsc --noEmit) || echo "FAIL $c"; done
```
Expected: no `FAIL` lines.

- [ ] **Step 3: Commit (core repo)**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add connectors/linkedin connectors/instagram connectors/whatsapp
git commit -m "feat(connectors): declare access copy on private connectors"
```

---

## Task 4: Core API — flow `access` through the provider path

**Files:**
- Modify: `workers/api/src/twist/entrypoint.ts` (`getSourceMetadata`, ~467-478)
- Modify: `workers/api/src/twist/factory.ts` (sourceProvider type ~94-103; scope block ~487-514)
- Modify: `workers/api/src/twist/tools/factory.ts` (`ProviderDeclaration` ~329-336; `mergeProviderDeclarations` ~353-387)
- Modify: `workers/api/src/twist/tools/integrations.ts` (`getIntegrationData` ~3754-3793)
- Modify: `workers/api/src/app/twist-integrations.ts` (`createReadOnlyIntegrations` ~164-204)

> ⚠️ `entrypoint.ts` is consumed as a template literal — never introduce a raw backtick. The edit below uses none.

- [ ] **Step 1: `getSourceMetadata` passes `access`**

In `workers/api/src/twist/entrypoint.ts`, inside the returned object of `getSourceMetadata` (after the `autoEnableNewChannelsByDefault` spread, ~line 477), add:
```javascript
        ...(twist.access ? { access: twist.access } : {}),
```

- [ ] **Step 2: factory `sourceProvider` type gains `access`**

In `workers/api/src/twist/factory.ts`, the inline `sourceProvider` type (~94-103) — add `access?: string[];`:
```typescript
    let sourceProvider: {
      provider?: string;
      scopes?: string[];
      linkTypes?: any[];
      handleReplies?: boolean;
      shared?: boolean;
      keyOption?: string;
      autoEnableNewChannelsByDefault?: boolean;
      access?: string[];
    } | null = null;
```

- [ ] **Step 3: factory feeds connector `access` into the ProviderDeclaration**

Replace the scope-resolution block (~487-514) so it reads `access` from the connector metadata (not from `ScopeConfig.description`):

```typescript
      // Collect and merge provider declarations from all Integrations instances
      const allProviders: ProviderDeclaration[] = [];
      for (const { id: toolId, options } of toolInstances) {
        allProviders.push(...collectToolProviders(toolId, options));
      }
      // For sources using the new API, add provider declaration from source metadata
      // Skip for no-provider connectors (provider is undefined)
      if (sourceProvider?.provider) {
        // Resolve scopes — the connector may declare string[] or ScopeConfig.
        // getSourceMetadata() passes through the raw value from the connector.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const rawScopes: any = sourceProvider.scopes;
        let requiredScopes: string[];
        let optionalScopes: any[] | undefined;
        if (Array.isArray(rawScopes)) {
          requiredScopes = rawScopes;
        } else if (rawScopes?.required) {
          requiredScopes = rawScopes.required;
          optionalScopes = rawScopes.optional;
        } else {
          requiredScopes = [];
        }
        allProviders.push({
          provider: sourceProvider.provider,
          scopes: requiredScopes,
          ...(optionalScopes ? { optionalScopes } : {}),
          ...(sourceProvider.access ? { access: sourceProvider.access } : {}),
        });
        // Normalize scopes to string[] so downstream consumers see a flat array
        sourceProvider = { ...sourceProvider, scopes: requiredScopes };
      }
      providers = mergeProviderDeclarations(allProviders);
```

- [ ] **Step 4: rename `description`→`access` in `ProviderDeclaration` + merge**

In `workers/api/src/twist/tools/factory.ts`, update the type (~329-336):
```typescript
export type ProviderDeclaration = {
  provider: string;
  scopes: string[];
  /** Plain-language bullets describing what connecting grants (Connector.access). */
  access?: string[];
  /** Optional scope groups the user can toggle before OAuth. */
  optionalScopes?: OptionalScopeGroup[];
};
```
And in `mergeProviderDeclarations` (~353-387), replace every `description` with `access`:
```typescript
  const byProvider = new Map<string, {
    scopes: Set<string>;
    access?: string[];
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
    if (decl.access && !entry.access) {
      entry.access = decl.access;
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
      ...(entry.access ? { access: entry.access } : {}),
      ...(entry.optionalScopes ? { optionalScopes: entry.optionalScopes } : {}),
    }));
```

- [ ] **Step 5: `getIntegrationData` dual-emits `access` + `description`**

In `workers/api/src/twist/tools/integrations.ts`, update the `getIntegrationData` return-type `providers` array (~3755) to include both keys:
```typescript
    providers: Array<{ provider: AuthProvider; scopes: string[]; optionalScopes?: any[]; access?: string[]; description?: string[] }>;
```
And the provider map (~3787-3792) — emit `access` plus a back-compat `description` mirror:
```typescript
    const providers = this.providerConfigs.map(p => ({
      provider: p.provider,
      scopes: p.scopes,
      ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
      ...((p as any).access ? { access: (p as any).access, description: (p as any).access } : {}),
    }));
```

- [ ] **Step 6: `createReadOnlyIntegrations` carries `access`**

In `workers/api/src/app/twist-integrations.ts`, the `providerConfigs` map inside `createReadOnlyIntegrations` (~177-181) — replace the `description` spread with `access`:
```typescript
  const providerConfigs = providers.map((p) => ({
    provider: p.provider as any,
    scopes: p.scopes,
    ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
    ...(p.access ? { access: p.access } : {}),
    getChannels: async () => [],
    onChannelEnabled: async () => {},
    onChannelDisabled: async () => {},
  }));
```

- [ ] **Step 7: typecheck the API worker**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/workers/api && pnpm exec tsc --noEmit
```
Expected: no errors. (If `p.access`/`p.description` raise "property does not exist" on a provider-config type elsewhere, widen that local type the same way — the `ProviderDeclaration`/providerConfig shape is the source.)

- [ ] **Step 8: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add workers/api/src/twist/entrypoint.ts workers/api/src/twist/factory.ts workers/api/src/twist/tools/factory.ts workers/api/src/twist/tools/integrations.ts workers/api/src/app/twist-integrations.ts
git commit -m "feat(api): flow connector access copy through provider path"
```

---

## Task 5: Core API — surface `access` on the credential (no-provider) route

**Files:**
- Modify: `workers/api/src/app/twist-integrations.ts` (no-provider branches ~252-271 and ~343-379)

- [ ] **Step 1: add `access` to the unconfigured no-provider response**

In the `if (config.providers.length === 0)` → `if (!hasConfig)` branch (~264-270), add `access` from the stored source metadata to the `c.json({...})`:
```typescript
      return c.json({
        providers: [], accounts: [], syncables: [], optionsSchema,
        access: config.sourceProvider?.access ?? null,
        shared: twistInfo.shared, keyOption: twistInfo.keyOption,
        premium: twistInfo.premium,
        accountLabel: twistInfo.accountLabel ?? null,
        teamName: twistInfo.teamName ?? null,
      });
```

- [ ] **Step 2: add `access` to the configured no-provider response**

In the configured branch's final `return c.json({...})` (~371-379), add the same line:
```typescript
    return c.json({
      providers: [], accounts, syncables, optionsSchema, optionsConfig,
      access: config.sourceProvider?.access ?? null,
      singleChannel: config.singleChannel,
      channelNoun: config.channelNoun,
      shared: twistInfo.shared,
      keyOption: twistInfo.keyOption,
      premium: twistInfo.premium,
      teamDomains,
      accountLabel: twistInfo.accountLabel ?? null,
      teamName: twistInfo.teamName ?? null,
    });
```

> If `config.sourceProvider` is not typed/visible in this scope, read it the same way the branch already reads `config.optionsSchema`/`config.singleChannel`. If TS complains it lacks `access`, cast: `(config.sourceProvider as any)?.access ?? null`.

- [ ] **Step 3: typecheck**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/workers/api && pnpm exec tsc --noEmit
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add workers/api/src/app/twist-integrations.ts
git commit -m "feat(api): surface access copy on credential connect response"
```

---

## Task 6: Flutter — model fields

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart` (`TwistProvider` ~842-874; `TwistIntegrations` ~740-839)

- [ ] **Step 1: `TwistProvider.description` → `access` (with back-compat read)**

Replace the `description` field, constructor param, `fromJson`, and `props` in `TwistProvider`:
```dart
class TwistProvider extends Equatable {
  final AuthProvider provider;
  final List<String> scopes;

  /// Plain-language bullets describing what connecting this service grants.
  final List<String> access;
  final List<OptionalScopeGroup>? optionalScopes;

  const TwistProvider({
    required this.provider,
    required this.scopes,
    this.access = const [],
    this.optionalScopes,
  });

  factory TwistProvider.fromJson(Map<String, dynamic> json) {
    return TwistProvider(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      // Back-compat: older servers send `description`.
      access:
          (json['access'] as List<dynamic>?)?.cast<String>() ??
          (json['description'] as List<dynamic>?)?.cast<String>() ??
          const [],
      optionalScopes: (json['optionalScopes'] as List<dynamic>?)
          ?.map((g) => OptionalScopeGroup.fromJson(g as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  List<Object?> get props => [provider, scopes, access, optionalScopes];
}
```

- [ ] **Step 2: add `access` to `TwistIntegrations`**

In `TwistIntegrations` add the field, constructor param, and `fromJson` read. Add the field after `optionsConfig` (~750):
```dart
  /// Plain-language "what you're granting" bullets for credential (no-provider)
  /// connectors. Null for OAuth connectors (those carry it per-provider).
  final List<String>? access;
```
Add to the constructor (after `this.optionsConfig,`):
```dart
    this.access,
```
Add to `fromJson` (after `optionsConfig:` line):
```dart
      access: (json['access'] as List<dynamic>?)?.cast<String>(),
```

- [ ] **Step 3: find and fix any remaining `provider.description` references**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
grep -rn "\.description" apps/plot/lib | grep -i "provider"
```
Expected: the only hit is in `command/twist.dart` (handled in Task 7). If other files read `TwistProvider.description`, change them to `.access`.

- [ ] **Step 4: analyze**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/apps/plot && flutter analyze lib/api/twist_api.dart
```
Expected: "No issues found!" (twist_api.dart is hand-written, no codegen needed).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add apps/plot/lib/api/twist_api.dart
git commit -m "feat(app): add access field to TwistProvider and TwistIntegrations"
```

---

## Task 7: Flutter — render `access` on both connect screens

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (OAuth widget ~3704-3706; credential insertion sites ~2045 and ~2248)

- [ ] **Step 1: OAuth widget reads `access`**

In `_AuthWithScopeTogglesState.build` (~3705-3706), change:
```dart
    final optionalScopes = widget.provider.optionalScopes;
    final description = widget.provider.description;
```
to:
```dart
    final optionalScopes = widget.provider.optionalScopes;
    final access = widget.provider.access;
```
Then in the bullets block (~3711-3712) change the two references:
```dart
        if (access.isNotEmpty) ...[
          for (final line in access)
```
(The rest of the block — padding, bullet Row, `line` — is unchanged.)

- [ ] **Step 2: add a reusable access-bullets builder for the credential screen**

Add a top-level helper near `_AuthWithScopeToggles` in `command/twist.dart`:
```dart
/// Builds the "what you're granting" bullet list shown above credential
/// (no-provider) connect fields. Returns null when there's nothing to show.
FormItem? _accessBulletsItem(List<String>? access) {
  if (access == null || access.isEmpty) return null;
  return FormInfo(
    key: 'access',
    divider: false,
    builder: (formContext) => Padding(
      padding: EdgeInsets.only(
        left: formContext.theme.spacing.xl,
        right: formContext.theme.spacing.xl,
        bottom: formContext.theme.spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in access)
            Padding(
              padding: EdgeInsets.only(bottom: formContext.theme.spacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: formContext.theme.typography.sm.copyWith(
                      color: formContext.theme.colors.mutedForeground,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: formContext.theme.typography.sm.copyWith(
                        color: formContext.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
```

> Verify the `FormItem` / `FormInfo` return type matches what the surrounding `...optionItems.items` list expects (it's the same type these lists already hold). If `FormInfo` is not the element type, return whatever element type `optionItems.items` is.

- [ ] **Step 3: insert at the first credential site (~2045-2047)**

Replace:
```dart
              if (optionItems != null &&
                  (refreshed.providers.isNotEmpty || refreshed.isEmpty))
                ...optionItems.items,
```
with:
```dart
              if (optionItems != null &&
                  (refreshed.providers.isNotEmpty || refreshed.isEmpty)) ...[
                ?_accessBulletsItem(refreshed.access),
                ...optionItems.items,
              ],
```

> `?_accessBulletsItem(...)` uses Dart's null-aware element (the list literal drops it when null). If the project's Dart version predates null-aware elements, use an explicit guard instead:
> ```dart
>               if (optionItems != null &&
>                   (refreshed.providers.isNotEmpty || refreshed.isEmpty)) ...[
>                 if (_accessBulletsItem(refreshed.access) case final item?) item,
>                 ...optionItems.items,
>               ],
> ```

- [ ] **Step 4: insert at the second credential site (~2248-2250)**

Replace:
```dart
              if (optionItems != null &&
                  (integrations.providers.isNotEmpty || integrations.isEmpty))
                ...optionItems.items,
```
with:
```dart
              if (optionItems != null &&
                  (integrations.providers.isNotEmpty || integrations.isEmpty)) ...[
                ?_accessBulletsItem(integrations.access),
                ...optionItems.items,
              ],
```

- [ ] **Step 5: analyze**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/apps/plot && flutter analyze lib/command/twist.dart
```
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add apps/plot/lib/command/twist.dart
git commit -m "feat(app): render connector access bullets on both connect screens"
```

---

## Task 8: Finalize — tests, lint, docs

**Files:**
- Possibly modify: existing API tests referencing provider `description`
- Modify: `docs/updates.md`

- [ ] **Step 1: update any tests asserting the old `description` shape**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
grep -rn "description" workers/api/src --include=*.test.ts | grep -iE "provider|scope|ScopeConfig|optionalScopes"
grep -rn "ScopeConfig" workers/api/src --include=*.test.ts
```
For each hit that asserts a provider's `description` field or sets `ScopeConfig.description`, update it: assertions on the emitted provider should accept `access` (the server still also emits `description` for back-compat, so existing `description` assertions may still pass — keep them if so, and add an `access` assertion). Remove any `ScopeConfig` test fixture that sets `description`.

- [ ] **Step 2: run the API test suite**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy/workers/api && pnpm test
```
Expected: all pass. Fix any failures caused by the rename.

- [ ] **Step 3: repo-relevant lint**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
pnpm --filter @plotday/api lint
cd apps/plot && flutter analyze lib/api/twist_api.dart lib/command/twist.dart
```
Expected: clean.

- [ ] **Step 4: add the user-facing changelog bullet**

In `docs/updates.md`, under `## Next release`, add (create a `### Connections` section if none exists, placed above `### Fixes`):
```markdown
### Connections

- The connect screen now explains, in plain language, exactly what access each connection grants — before you authorize it.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/connector-access-copy
git add workers/api docs/updates.md
git commit -m "test+docs: connector access copy"
```

- [ ] **Step 6: Finalization handoff**

- Public submodule (`public/`) branch `feat/connector-access-copy` → open its own PR (twister `Connector.access` + `ScopeConfig.description` removal + changeset + all public connector copy). Merge it before the core pointer bump.
- Core repo branch `connector-access-copy` → bump the `public` submodule pointer after the public PR merges, then open the core PR (API wiring + Flutter + private connectors + docs).
- Run the `run-app` skill to visually verify: one OAuth connector (e.g. Linear), one credential connector (e.g. PostHog/Attio), and one Unipile connector (e.g. WhatsApp) each show the `access` bullets on their connect screen. (OAuth consent verification needs a real account.)

---

## Self-Review Notes

- **Spec coverage:** SDK field (Task 1), all 15 public + 3 private connectors incl. gcal migration & slack (Tasks 2-3), provider path A (Task 4), credential path B (Task 5), Flutter models + rendering for both screens incl. Unipile via provider path (Tasks 6-7), back-compat dual-emit (Task 4 Step 5 + Task 6 Step 1), changeset (Task 1), docs + finalization (Task 8). google-contacts and notion intentionally excluded per spec.
- **Type consistency:** core internal field renamed `description`→`access` consistently across `ProviderDeclaration`, `mergeProviderDeclarations`, `createReadOnlyIntegrations`, and `getIntegrationData` (which additionally mirrors to `description` on the wire only). Flutter `TwistProvider.access` (List<String>, default `const []`) and `TwistIntegrations.access` (List<String>?, nullable) — the OAuth widget reads the former, the credential screen reads the latter via `_accessBulletsItem`.
- **Back-compat:** wire keeps emitting `description` (= access) for provider connectors; new Flutter reads `access ?? description`. No removed wire fields.
