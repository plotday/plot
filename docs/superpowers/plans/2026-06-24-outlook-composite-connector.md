# Outlook Composite Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Combine `outlook-mail` and `outlook-calendar` into one `@plotday/connector-outlook` composite connection (products: Mail, Calendar, Contacts), mirroring the Google composite.

**Architecture:** Refactor each underlying connector into `channels.ts` (channel listing + scope + link-type exports) and `sync.ts` (a `*SyncHost` interface + host-pattern functions), leaving the standalone connector as a thin driver — exactly how `gmail`/`google-calendar` were refactored. A new `outlook` composite package imports those exports, owns scheduling, namespaces channel ids `<product>:<rawId>`, and dispatches lifecycle/webhooks/write-backs per product. No core Flutter/API/DB change (the machinery is provider-agnostic); only one gated `apps/site` registry entry.

**Tech Stack:** TypeScript, `@plotday/twister` SDK, Cloudflare Workers runtime, Microsoft Graph API, vitest, pnpm workspaces.

**Reference spec:** `docs/superpowers/specs/2026-06-24-outlook-composite-connection-design.md`

**Primary templates to mirror (read these first):**
- Composite shell: `public/connectors/google/src/{google.ts, compose.ts, product-channel.ts, product-status.ts, scopes.ts, products/*}`
- Mail extraction pattern: `public/connectors/gmail/src/{channels.ts, sync.ts, gmail.ts, index.ts}`
- Calendar extraction pattern: `public/connectors/google-calendar/src/{channels.ts, sync.ts, google-calendar.ts, index.ts}`

## Global Constraints

- **No source-key format changes.** Sync must keep emitting `outlook-mail:<accountEmail>:<conversationId>` (note key `internetMessageId`) and `outlook-calendar:<calendarId>:<eventId>` + aliases `icaluid:<iCalUID>`, `outlook-event:<eventId>`. These are the cross-user dedup + future-cutover convergence keys. Changing them is a regression.
- **Standalone connectors stay deployable and behaviorally unchanged.** `OutlookMail`/`OutlookCalendar` keep their existing `provider`, `scopes` (incl. Mail's `MergeScopes(..., OUTLOOK_PEOPLE_SCOPES)`), `linkTypes`, and public class. The refactor is internal: move logic into host-pattern functions, drive them from the class via a self-host.
- **Behavior-preserving refactor.** Phases A–B add no features. The existing `outlook-mail` test suite (`email-parsing.test.ts`, `enrich.test.ts`, `graph-mail-api.test.ts`, `outlook-facets.test.ts`, `outlook-mail.test.ts`) is the regression net — it must stay green at every commit.
- **Three-way invariant** in the composite: `scopeGroup.id === product.key === channel-id prefix` ∈ {`mail`, `calendar`, `contacts`}.
- **Microsoft scopes:** mail = `https://graph.microsoft.com/mail.readwrite`, `https://graph.microsoft.com/mail.send`; calendar = `https://graph.microsoft.com/calendars.readwrite`; contacts = `https://graph.microsoft.com/people.read`, `https://graph.microsoft.com/contacts.read`.
- **New package id:** generate the composite's `plotTwistId` with `plot create --connector` (or `npx plot create`). Never hand-author the UUID.
- **Deploy gating:** do NOT add `@plotday/connector-outlook` to `connectors/deploy.json` `public` list (review-only). Site entry `available: false`.
- **Per-package gates** before any commit in that package: `pnpm build` (tsc) green, `pnpm exec tsc --noEmit` green, `pnpm lint` (`plot lint`) green, and that package's `vitest run` green.
- Follow `public/connectors/AGENTS.md` connector rules (callback tokens not functions; `runTask` not `run` in `onChannelEnabled`; localhost guard on webhooks; `initialSync` propagation; clean teardown).

---

## Task 0: Worktree + workspace baseline

**Files:**
- Create: git worktree off `origin/main`
- Modify: none yet

**Why a worktree:** the main folder has concurrent agents mutating the tree (observed mid-session). This work touches the `public/` submodule and two large files; isolation is required. No DB/schema work, so no `worktree-db` needed.

- [ ] **Step 1: Create the worktree** via the `superpowers:using-git-worktrees` skill (native tool), branch `outlook-composite-connector`, base `origin/main`. The WorktreeCreate hook handles submodule init (`--reference`), env copy, and `pnpm install`.

- [ ] **Step 2: Create a feature branch in the `public/` submodule** (composite + connector changes live there and need their own PR):

```bash
cd public && git checkout -b outlook-composite-connector && cd ..
```

- [ ] **Step 3: Baseline the existing connector tests (the regression net).**

Run:
```bash
cd public/connectors/outlook-mail && pnpm install >/dev/null 2>&1; pnpm exec vitest run
cd ../outlook-calendar && pnpm exec tsc --noEmit
```
Expected: outlook-mail tests PASS (record the count); outlook-calendar typechecks clean. This is the green baseline Phases A–B must preserve.

- [ ] **Step 4: Commit nothing** (worktree setup only). Proceed.

---

## Phase A — Refactor `outlook-mail` (extract, keep class working)

Mirror `gmail/src/{channels.ts, sync.ts}` + thin `gmail.ts`. Source class today: `public/connectors/outlook-mail/src/outlook-mail.ts` (methods catalogued below).

### Task A1: Extract `outlook-mail/src/channels.ts`

**Files:**
- Create: `public/connectors/outlook-mail/src/channels.ts`
- Modify: `public/connectors/outlook-mail/src/outlook-mail.ts` (`getChannels` body → call new fn; lift scope/link-type constants), `public/connectors/outlook-mail/src/index.ts`
- Test: existing `outlook-mail.test.ts` (regression)

**Interfaces:**
- Produces (for the composite and the thin class):
  - `OUTLOOK_MAIL_SCOPES: string[]` — `["https://graph.microsoft.com/mail.readwrite", "https://graph.microsoft.com/mail.send"]`
  - `OUTLOOK_MAIL_LINK_TYPES: LinkTypeConfig[]` — the exact `linkTypes` array currently inline in `outlook-mail.ts:226-…` (the `email` type with `contactRoles` To/CC/BCC and `compose.targets: "addresses"`).
  - `getOutlookMailChannels(token: AuthToken): Promise<Channel[]>` — the folder-listing logic currently inside `OutlookMail.getChannels` (`outlook-mail.ts:376-398`), using `GraphMailApi` + `EXCLUDED_WELL_KNOWN` from `graph-mail-api.ts`. Preserve current default-enable behavior.

- [ ] **Step 1: Create `channels.ts`** with the three exports above. Move the inline `linkTypes` constant and the scope strings verbatim; move the folder-listing logic out of `getChannels`. Pattern: `public/connectors/gmail/src/channels.ts`.

- [ ] **Step 2: Rewire the class.** In `outlook-mail.ts`, replace the inline `linkTypes` with `readonly linkTypes = OUTLOOK_MAIL_LINK_TYPES;`, keep `readonly scopes = Integrations.MergeScopes(OUTLOOK_MAIL_SCOPES, OUTLOOK_PEOPLE_SCOPES);` (use the new constant for the mail half), and make `getChannels` delegate: `return getOutlookMailChannels(token);` (preserve the existing `null`-token guard).

- [ ] **Step 3: Export from index.** Add to `public/connectors/outlook-mail/src/index.ts`:
```ts
export { getOutlookMailChannels, OUTLOOK_MAIL_SCOPES, OUTLOOK_MAIL_LINK_TYPES } from "./channels";
```

- [ ] **Step 4: Verify green.**
Run: `cd public/connectors/outlook-mail && pnpm exec tsc --noEmit && pnpm exec vitest run`
Expected: typecheck clean; all existing tests PASS (same count as the Task 0 baseline).

- [ ] **Step 5: Commit.**
```bash
cd public && git add connectors/outlook-mail/src/channels.ts connectors/outlook-mail/src/outlook-mail.ts connectors/outlook-mail/src/index.ts
git commit -m "refactor(outlook-mail): extract channels.ts (scopes, link types, getChannels)"
```

### Task A2: Extract `outlook-mail/src/sync.ts` (host-pattern functions)

**Files:**
- Create: `public/connectors/outlook-mail/src/sync.ts`
- Modify: `public/connectors/outlook-mail/src/outlook-mail.ts` (class becomes a thin driver), `public/connectors/outlook-mail/src/index.ts`
- Test: existing `outlook-mail.test.ts` (regression — adapt mocks to the host as gmail's tests do)

**Interfaces:**
- Produces:
  - `OutlookMailSyncHost` interface — copy the shape of `GmailSyncHost` (`gmail/src/sync.ts`): `set/get/clear`, `tools.integrations` (`get`, `saveLink`/`saveLinks`, `channelSyncCompleted`, `archiveLinks`), `tools.files` (attachment download target), `tools.store` (`acquireLock`, `releaseLock`, `list`), and a `scheduler` block of bound references for the operations that must schedule (`callback`, `runTask`, `scheduleRecurring`, `cancelScheduledTask`) — gmail uses exactly this `host.scheduler.*` approach; follow it.
  - Host-pattern functions extracted from these `OutlookMail` methods (one exported `*Fn` per method, taking `host` as the first arg), preserving names/behavior:
    - subscription lifecycle: `ensureMailboxSubscriptionFn`, `setupMailboxSubscriptionFn`, `teardownMailboxSubscriptionFn`, `scheduleMailboxRenewalFn`, `renewMailboxSubscriptionFn` (`outlook-mail.ts:568-769`)
    - self-heal: `scheduleSelfHealCheckFn`, `selfHealCheckFn`, `folderDeltaCatchUpFn` (`:770-954`)
    - sync: `initialSyncBatchFn`, `fetchConversationsFn`, `onOutlookMailWebhookFn`, `incrementalSyncBatchFn`, `mergePendingMessagesFn`, `processConversationsFn` (`:955-1413`)
    - write-back/read: `onThreadReadFn`, `onThreadToDoFn`, `onNoteCreatedFn`, `onCreateLinkFn`, `downloadAttachmentFn` (`:1414-1851`)
    - channel/account helpers: `getApiFn`, `getApiAnyFn`, `getEnabledChannelsFn`, `addEnabledChannelFn`, `removeEnabledChannelFn`, `isChannelEnabledFn`, `ensureUserEmailFn`, `getWellKnownFn` (`:492-567`)
    - recovery: `recoverMailboxDeliveryFn`, `requeueInitialSyncFn`, `upgradeFn` (`:288-368`)
  - The enrichment call stays via `enrichLinkContactsFromOutlook(links, token, scopes)` from `./enrich`, invoked inside the sync path using `token.scopes` (so it degrades when contacts scope absent).

- [ ] **Step 1: Define the host interface** `OutlookMailSyncHost` in `sync.ts`, copying `GmailSyncHost`'s structure and trimming to the tools OutlookMail actually uses (`integrations`, `files`, `store`, `scheduler`). Include `tools.integrations.archiveLinks` if `onChannelDisabled` bulk-archives.

- [ ] **Step 2: Move each method body** listed above into an exported `*Fn(host, …)` function. Mechanical transform: `this.set/get/clear` → `host.set/get/clear`; `this.tools.X` → `host.tools.X`; `this.tools.store.acquireLock/releaseLock/list` → `host.tools.store.*`; `this.callback/runTask/scheduleRecurring/cancelScheduledTask` → `host.scheduler.callback/runTask/scheduleRecurring/cancelScheduledTask`; calls to sibling methods → calls to the sibling `*Fn(host, …)`. Keep all Graph/API/transform calls (`GraphMailApi`, `transformOutlookConversation`, `email-parsing`, `outlook-facets`) unchanged.

- [ ] **Step 3: Rewire the class to a thin driver.** In `outlook-mail.ts`, build a `private host(): OutlookMailSyncHost` returning `{ set: (k,v)=>this.set(k,v), get: (k)=>this.get(k), clear: (k)=>this.clear(k), tools: { integrations: this.tools.integrations, files: this.tools.files, store: this.tools.store }, scheduler: { callback: this.callback.bind(this), runTask: this.runTask.bind(this), scheduleRecurring: this.scheduleRecurring.bind(this), cancelScheduledTask: this.cancelScheduledTask.bind(this) } }`. Replace each public/lifecycle method body with a delegation to the matching `*Fn(this.host(), …)`. (Callbacks like `selfHealCheck`, `renewMailboxSubscription`, `initialSyncBatch`, `incrementalSyncBatch`, `onOutlookMailWebhook` must remain methods on the class — the runtime invokes them by name — but their bodies are one-line delegations.) Mirror `gmail/src/gmail.ts`.

- [ ] **Step 4: Export the sync surface from index.** Append to `index.ts` the `type OutlookMailSyncHost` and every `*Fn` + state-type the composite will import (mirror `gmail/src/index.ts`'s second export block).

- [ ] **Step 5: Adapt the existing test mocks** so `outlook-mail.test.ts` constructs/asserts against the host where it previously used `this`. Gmail's `gmail.test.ts` shows the spy/host pattern. Do NOT add new behavior — keep assertions identical.

- [ ] **Step 6: Verify green.**
Run: `cd public/connectors/outlook-mail && pnpm exec tsc --noEmit && pnpm exec vitest run`
Expected: typecheck clean; all tests PASS (same count as baseline). If a test now needs the host, it asserts the same outcome.

- [ ] **Step 7: Commit.**
```bash
cd public && git add connectors/outlook-mail/src/sync.ts connectors/outlook-mail/src/outlook-mail.ts connectors/outlook-mail/src/index.ts connectors/outlook-mail/src/outlook-mail.test.ts
git commit -m "refactor(outlook-mail): extract sync.ts host-pattern functions; thin driver class"
```

---

## Phase B — Refactor `outlook-calendar` (same treatment)

Mirror `google-calendar/src/{channels.ts, sync.ts}`. Source: `public/connectors/outlook-calendar/src/outlook-calendar.ts`. Note: this package currently has **no tests**, so the gate is `tsc --noEmit` + `plot lint` + a careful behavior-preserving diff. Extract conservatively.

### Task B1: Extract `outlook-calendar/src/channels.ts`

**Files:**
- Create: `public/connectors/outlook-calendar/src/channels.ts`
- Modify: `public/connectors/outlook-calendar/src/outlook-calendar.ts`, `public/connectors/outlook-calendar/src/index.ts`

**Interfaces:**
- Produces:
  - `OUTLOOK_CALENDAR_SCOPE: string` — `"https://graph.microsoft.com/calendars.readwrite"`
  - `OUTLOOK_CALENDAR_LINK_TYPES: LinkTypeConfig[]` — the exact `linkTypes` array inline at `outlook-calendar.ts:163` (the `event` type, `includesSchedules: true`).
  - `getOutlookCalendarChannels(token: AuthToken): Promise<Channel[]>` — the calendar-listing logic currently in `OutlookCalendar.getChannels` (`:190-216`), using `GraphApi`. Preserve owned-vs-shared default-enable behavior and the `accessRole`-based defaults.

- [ ] **Step 1: Create `channels.ts`** with the three exports (mirror `google-calendar/src/channels.ts`, including a `Calendar` type if the listing produces one).

- [ ] **Step 2: Rewire the class:** `readonly linkTypes = OUTLOOK_CALENDAR_LINK_TYPES;`, `static readonly SCOPES = [OUTLOOK_CALENDAR_SCOPE];`, `getChannels` delegates to `getOutlookCalendarChannels(token)`.

- [ ] **Step 3: Export from index:**
```ts
export { getOutlookCalendarChannels, OUTLOOK_CALENDAR_SCOPE, OUTLOOK_CALENDAR_LINK_TYPES } from "./channels";
```

- [ ] **Step 4: Verify green.**
Run: `cd public/connectors/outlook-calendar && pnpm exec tsc --noEmit && pnpm exec plot lint`
Expected: clean.

- [ ] **Step 5: Commit.**
```bash
cd public && git add connectors/outlook-calendar/src/channels.ts connectors/outlook-calendar/src/outlook-calendar.ts connectors/outlook-calendar/src/index.ts
git commit -m "refactor(outlook-calendar): extract channels.ts (scope, link types, getChannels)"
```

### Task B2: Extract `outlook-calendar/src/sync.ts` (host-pattern functions)

**Files:**
- Create: `public/connectors/outlook-calendar/src/sync.ts`
- Modify: `public/connectors/outlook-calendar/src/outlook-calendar.ts`, `public/connectors/outlook-calendar/src/index.ts`

**Interfaces:**
- Produces:
  - `OutlookCalendarSyncHost` interface — copy `CalendarSyncHost` (`google-calendar/src/sync.ts`): `set/get/clear`, `tools.integrations` (`get`, `saveLinks`, `channelSyncCompleted`), `tools.store` (`acquireLock`, `releaseLock`, `list`). Outlook calendar uses the **descriptor** scheduling style (functions return "next/done" descriptors; the caller schedules) — mirror google-calendar, not gmail.
  - Host-pattern functions from these `OutlookCalendar` methods, preserving names/behavior:
    - init/lifecycle: `initCalendarFn`, `startSyncFn`, `stopSyncFn`, `clearBuffersFn`, `firstSeenAtFn` (`:295-542`)
    - watch: `scheduleSubscriptionRenewalFn`, `renewOutlookWatchFn`, `setupOutlookWatchFn` (`:543-706`)
    - sync: `syncOutlookBatchFn`, `processOutlookEventsFn`, `prepareEventInstanceFn` (`:707-1433`)
    - webhook/incremental: `onOutlookWebhookFn`, `startIncrementalSyncFn` (`:1434-1521`)
    - RSVP write-back: `onScheduleContactUpdatedFn`, `updateEventRSVPWithApiFn` (`:1522-1610`)
    - account helpers: `getApiFn`, `tryGetApiFn`, `getUserEmailFn`, `ensureUserIdentityFn`, `getCalendarsFn` (`:369-427`)
  - `buildEventSources(...)` and any `SyncState` type that the composite needs — re-export from `graph-api.ts` if already there, else from `sync.ts`. Keep source format identical (Global Constraint).

- [ ] **Step 1: Define `OutlookCalendarSyncHost`** in `sync.ts` (copy `CalendarSyncHost` shape).

- [ ] **Step 2: Move each method body** into an exported `*Fn(host, …)`. Same mechanical transform as A2, but where a function needs to schedule the next batch/renewal, **return a descriptor** (mirror `runCalendarInit`/`runSyncBatch`/`getWatchRenewalScheduleFn` in `google-calendar/src/sync.ts`) and let the class own `this.callback/runTask/scheduleRecurring`. Keep `GraphApi`, `transformOutlookEvent`, recurrence parsing, and the `pending_occ:`/`seen_master:` buffering logic unchanged.

- [ ] **Step 3: Rewire the class to a thin driver.** Add `private host(): OutlookCalendarSyncHost`; replace method bodies with delegations; the class retains `initCalendar`, `syncOutlookBatch`, `renewOutlookWatch`, `onOutlookWebhook`, `startIncrementalSync`, `onScheduleContactUpdated` as named methods (runtime-invoked callbacks) whose bodies call the `*Fn` and act on returned descriptors via `this.callback`/`this.runTask`/`this.scheduleRecurring`. Mirror `google-calendar/src/google-calendar.ts`. Preserve `autoEnableNewChannelsByDefault = true`.

- [ ] **Step 4: Export the sync surface** from `index.ts` (mirror `google-calendar/src/index.ts`'s second block): `type OutlookCalendarSyncHost`, every `*Fn`, descriptor/state types, and `buildEventSources`.

- [ ] **Step 5: Verify green.**
Run: `cd public/connectors/outlook-calendar && pnpm exec tsc --noEmit && pnpm exec plot lint`
Expected: clean.

- [ ] **Step 6: Commit.**
```bash
cd public && git add connectors/outlook-calendar/src/sync.ts connectors/outlook-calendar/src/outlook-calendar.ts connectors/outlook-calendar/src/index.ts
git commit -m "refactor(outlook-calendar): extract sync.ts host-pattern functions; thin driver class"
```

---

## Phase C — Scaffold the `outlook` composite package

### Task C1: Package skeleton + copied scaffolding

**Files:**
- Create: `public/connectors/outlook/{package.json, tsconfig.json, vitest.config.ts, README.md, src/index.ts}`
- Create: `public/connectors/outlook/src/{product-channel.ts, product-status.ts, compose.ts}`
- Test: `public/connectors/outlook/test/{product-channel.test.ts, product-status.test.ts, compose.test.ts}`

**Interfaces:**
- Consumes: `Product` (defined in Task C3).
- Produces: `namespace/parse/productKeyOf` (product-channel), `computeProductStatus` + types (product-status), `composeChannels/resolveProductForChannelId/resolveProductForLinkType` (compose) — all identical to the Google package.

- [ ] **Step 1: Scaffold the package** by copying `public/connectors/google/{tsconfig.json, vitest.config.ts}` and authoring `package.json`:
```jsonc
{
  "name": "@plotday/connector-outlook",
  "plotTwistId": "<GENERATE via `plot create --connector`>",
  "displayName": "Outlook",
  "description": "Email, calendar, and contacts from your Outlook account.",
  "category": "messaging",
  "logoUrl": "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
  "publisher": "Plot", "publisherUrl": "https://plot.day",
  "author": "Plot <team@plot.day> (https://plot.day)", "license": "MIT",
  "version": "0.1.0", "type": "module", "private": true,
  "main": "./dist/index.js", "types": "./dist/index.d.ts",
  "exports": { ".": { "@plotday/connector": "./src/index.ts", "types": "./dist/index.d.ts", "default": "./dist/index.js" } },
  "scripts": { "build": "tsc", "clean": "rm -rf dist", "deploy": "plot deploy", "lint": "plot lint", "test": "vitest run", "test:watch": "vitest" },
  "dependencies": {
    "@plotday/connector-outlook-mail": "workspace:^",
    "@plotday/connector-outlook-calendar": "workspace:^",
    "@plotday/twister": "workspace:^"
  },
  "devDependencies": { "typescript": "^5.9.3", "vitest": "^2.1.8" },
  "repository": { "type": "git", "url": "https://github.com/plotday/plot.git", "directory": "connectors/outlook" },
  "homepage": "https://plot.day",
  "keywords": ["plot", "connector", "outlook", "microsoft", "mail", "calendar", "contacts", "messaging"]
}
```
Use the real generated UUID for `plotTwistId`.

- [ ] **Step 2: Copy the three pure scaffolding files verbatim** from `public/connectors/google/src/` to `public/connectors/outlook/src/`: `product-channel.ts`, `product-status.ts`, `compose.ts`. (They reference `./products/product` for the `Product` type only — that resolves after Task C3.)

- [ ] **Step 3: Copy the matching tests** `product-channel.test.ts`, `product-status.test.ts`, `compose.test.ts` from `google/test/` to `outlook/test/`, adjusting product keys in fixtures to `mail`/`calendar`/`contacts`.

- [ ] **Step 4: Register the workspace + install.**
Run: `cd <worktree-root> && pnpm install`
Expected: `@plotday/connector-outlook` resolves (covered by the existing `public/connectors/*` workspace glob). If not covered, add the path to `pnpm-workspace.yaml`.

- [ ] **Step 5: Defer build/test to C3** (needs `Product`/`scopes`). Do not commit yet — fold this commit into C3.

### Task C2: `scopes.ts` (scope groups + products metadata)

**Files:**
- Create: `public/connectors/outlook/src/scopes.ts`
- Test: `public/connectors/outlook/test/scopes.test.ts`

**Interfaces:**
- Produces: `OUTLOOK_SCOPES: ScopeConfig`, `OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[]`, `PRODUCTS: ProductInfo[]`, `ProductInfo` type.

- [ ] **Step 1: Write the failing test** `scopes.test.ts` asserting the three-way invariant and group/scope values:
```ts
import { describe, it, expect } from "vitest";
import { OPTIONAL_SCOPE_GROUPS, PRODUCTS } from "../src/scopes";

describe("outlook scopes", () => {
  it("defines mail, calendar, contacts groups with matching ids", () => {
    expect(OPTIONAL_SCOPE_GROUPS.map(g => g.id)).toEqual(["mail", "calendar", "contacts"]);
  });
  it("each product's scopeGroupId equals its key (three-way invariant)", () => {
    for (const p of PRODUCTS) expect(p.scopeGroupId).toBe(p.key);
  });
  it("mail group carries readwrite + send scopes", () => {
    const mail = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "mail")!;
    expect(mail.scopes).toEqual([
      "https://graph.microsoft.com/mail.readwrite",
      "https://graph.microsoft.com/mail.send",
    ]);
  });
  it("contacts group carries people.read + contacts.read", () => {
    const c = OPTIONAL_SCOPE_GROUPS.find(g => g.id === "contacts")!;
    expect(c.scopes).toEqual([
      "https://graph.microsoft.com/people.read",
      "https://graph.microsoft.com/contacts.read",
    ]);
  });
});
```

- [ ] **Step 2: Run it, expect FAIL** (`Cannot find module '../src/scopes'`).
Run: `cd public/connectors/outlook && pnpm exec vitest run test/scopes.test.ts`

- [ ] **Step 3: Implement `scopes.ts`** mirroring `google/src/scopes.ts`:
```ts
import type { ScopeConfig, OptionalScopeGroup } from "@plotday/twister";

export const OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[] = [
  { id: "mail", label: "Mail", default: true,
    scopes: ["https://graph.microsoft.com/mail.readwrite", "https://graph.microsoft.com/mail.send"] },
  { id: "calendar", label: "Calendar", default: true,
    scopes: ["https://graph.microsoft.com/calendars.readwrite"] },
  { id: "contacts", label: "Contacts", default: true,
    scopes: ["https://graph.microsoft.com/people.read", "https://graph.microsoft.com/contacts.read"] },
];

export const OUTLOOK_SCOPES: ScopeConfig = { required: [], optional: OPTIONAL_SCOPE_GROUPS };

export interface ProductInfo {
  key: "mail" | "calendar" | "contacts";
  label: string; description: string; icon: string; scopeGroupId: string;
}

export const PRODUCTS: ProductInfo[] = [
  { key: "mail", label: "Outlook Mail", scopeGroupId: "mail",
    description: "Turns email into threads; sends replies and updates flags from Plot.",
    icon: "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4" },
  { key: "calendar", label: "Outlook Calendar", scopeGroupId: "calendar",
    description: "Adds your events to your agenda and writes your RSVPs.",
    icon: "https://api.iconify.design/fluent-emoji/calendar.svg" },
  { key: "contacts", label: "Outlook Contacts", scopeGroupId: "contacts",
    description: "Recognizes people by name on your threads.",
    icon: "https://api.iconify.design/material-symbols/contacts.svg" },
];
```
(Icons provisional — verify per AGENTS.md Connector Icon Guidelines before go-live.)

- [ ] **Step 4: Run it, expect PASS.**
Run: `cd public/connectors/outlook && pnpm exec vitest run test/scopes.test.ts`

### Task C3: `products/` modules (Product interface + registry + product records)

**Files:**
- Create: `public/connectors/outlook/src/products/{product.ts, mail.ts, calendar.ts, contacts.ts}`

**Interfaces:**
- Consumes: `getOutlookMailChannels`, `OUTLOOK_MAIL_SCOPES`, `OUTLOOK_MAIL_LINK_TYPES` (Task A1); `getOutlookCalendarChannels`, `OUTLOOK_CALENDAR_SCOPE`, `OUTLOOK_CALENDAR_LINK_TYPES` (Task B1); contacts scopes (Task C2).
- Produces: `Product` interface, `PRODUCTS_BY_KEY`, `mailProduct`, `calendarProduct`, `contactsProduct`.

- [ ] **Step 1: Create `product.ts`** copying `google/src/products/product.ts`, changing `key` union to `"mail" | "calendar" | "contacts"` and the `PRODUCTS_BY_KEY` registry to `{ mail: mailProduct, calendar: calendarProduct, contacts: contactsProduct }`.

- [ ] **Step 2: Create `mail.ts`** (mirror `google/src/products/mail.ts`):
```ts
import { getOutlookMailChannels, OUTLOOK_MAIL_SCOPES, OUTLOOK_MAIL_LINK_TYPES } from "@plotday/connector-outlook-mail";
import type { Product } from "./product";
export const mailProduct: Product = {
  key: "mail",
  requiredScopes: OUTLOOK_MAIL_SCOPES,
  linkTypes: OUTLOOK_MAIL_LINK_TYPES,
  getRawChannels: (token) => getOutlookMailChannels(token),
  onEnable: async () => { throw new Error("Mail onEnable handled by Outlook.onChannelEnabled"); },
  onDisable: async () => { throw new Error("Mail onDisable handled by Outlook.onChannelDisabled"); },
};
```

- [ ] **Step 3: Create `calendar.ts`** (mirror `google/src/products/calendar.ts`):
```ts
import { getOutlookCalendarChannels, OUTLOOK_CALENDAR_SCOPE, OUTLOOK_CALENDAR_LINK_TYPES } from "@plotday/connector-outlook-calendar";
import type { Product } from "./product";
export const calendarProduct: Product = {
  key: "calendar",
  requiredScopes: [OUTLOOK_CALENDAR_SCOPE],
  linkTypes: OUTLOOK_CALENDAR_LINK_TYPES,
  getRawChannels: (token) => getOutlookCalendarChannels(token),
  onEnable: async () => { throw new Error("Calendar onEnable handled by Outlook.onChannelEnabled"); },
  onDisable: async () => { throw new Error("Calendar onDisable handled by Outlook.onChannelDisabled"); },
};
```

- [ ] **Step 4: Create `contacts.ts`** (channelless; mirror `google/src/products/contacts.ts` but no import sync — enrichment is gated by scope only):
```ts
import type { Product } from "./product";
import type { Channel } from "@plotday/twister/tools/integrations";
export const CONTACTS_SCOPES = [
  "https://graph.microsoft.com/people.read",
  "https://graph.microsoft.com/contacts.read",
];
const SYNTHETIC: Channel = { id: "contacts", title: "Contacts", enabledByDefault: true };
export const contactsProduct: Product = {
  key: "contacts",
  requiredScopes: CONTACTS_SCOPES,
  linkTypes: [],
  channelless: true,
  // One synthetic channel so the API-side enabledChannelCount is >=1 when on.
  getRawChannels: async () => [SYNTHETIC],
  // No-op: Outlook has no contacts import. Enabling only grants the enrichment
  // scopes, which Mail's sync reads via token.scopes. seed_default_channels
  // auto-enables this owned synthetic channel on reconnect.
  onEnable: async () => {},
  onDisable: async () => {},
};
```

- [ ] **Step 5: Build + run scaffolding tests.**
Run: `cd public/connectors/outlook && pnpm exec tsc --noEmit && pnpm exec vitest run`
Expected: typecheck clean; `product-channel`, `product-status`, `compose`, `scopes` tests PASS.

- [ ] **Step 6: Commit C1–C3.**
```bash
cd public && git add connectors/outlook
git commit -m "feat(outlook): scaffold composite package (scopes, products, scaffolding + tests)"
```

---

## Phase D — Composite class: Mail wiring

### Task D1: `outlook.ts` skeleton + getChannels + Mail lifecycle/dispatch

**Files:**
- Create: `public/connectors/outlook/src/outlook.ts`, finalize `public/connectors/outlook/src/index.ts`
- Reference: `public/connectors/google/src/google.ts` (the authoritative template — replicate its structure for the Mail product).

**Interfaces:**
- Consumes: composite scaffolding (C1–C3), `outlook-mail` sync surface (A2).
- Produces: `class Outlook extends Connector<Outlook>` + `default`.

- [ ] **Step 1: Write the class declaration + build()** mirroring `google.ts:107-142`:
```ts
export class Outlook extends Connector<Outlook> {
  static readonly handleReplies = true;
  readonly provider = AuthProvider.Microsoft;
  readonly dynamicLinkTypes = true;
  readonly scopes = OUTLOOK_SCOPES;
  readonly products = PRODUCTS;
  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      files: build(Files),
    };
  }

  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.makeMailHost().set("auth_actor_id", context.actor.id);
  }

  async getChannels(_auth: Authorization | null, token: AuthToken | null): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }
}
export default Outlook;
```

- [ ] **Step 2: Implement `makeMailHost()`** returning an `OutlookMailSyncHost` whose `set/get/clear` prefix keys with `mail:`, and whose `tools.store.acquireLock/releaseLock/list` prefix `mail:` (stripping it on `list`), with `scheduler` bound to `this.callback/runTask/scheduleRecurring/cancelScheduledTask`. Copy the structure of `google.ts:makeMailHost()` (`:604-641`).

- [ ] **Step 3: Implement `onChannelEnabled`/`onChannelDisabled` dispatch** (mirror `google.ts:144-207`): `parse(channel.id)`; for `mail` call the Mail enable/disable path through `*Fn(this.makeMailHost(), rawId, context)` (initial sync queue + `ensureMailboxSubscriptionFn`); other product keys handled in Phases E–F.

- [ ] **Step 4: Add the Mail callback methods** the runtime invokes by name — `mailInitialSyncBatch`, `mailIncrementalSync`, `onGmail… → onOutlookMailWebhook`, `renewMailboxSubscription`, `selfHealCheck` — each a thin delegation to the matching `*Fn(this.makeMailHost(), …)` and re-scheduling via `this.runTask`. Mirror `google.ts` mail methods (`:703-782`).

- [ ] **Step 5: Finalize `index.ts`:** `export { default, Outlook } from "./outlook";`

- [ ] **Step 6: Build.**
Run: `cd public/connectors/outlook && pnpm exec tsc --noEmit && pnpm exec plot lint`
Expected: clean.

- [ ] **Step 7: Commit.**
```bash
cd public && git add connectors/outlook/src/outlook.ts connectors/outlook/src/index.ts
git commit -m "feat(outlook): composite class with Mail product wiring + getChannels"
```

---

## Phase E — Composite class: Calendar wiring

### Task E1: Calendar host + lifecycle + watch dispatch

**Files:**
- Modify: `public/connectors/outlook/src/outlook.ts`
- Reference: `google.ts` calendar section (`:251-574`).

**Interfaces:**
- Consumes: `outlook-calendar` sync surface (B2).

- [ ] **Step 1: Implement `makeCalendarHost()`** (`calendar:`-prefixed host; descriptor-style — no `scheduler` block needed, the class owns scheduling per B2). Copy `google.ts:makeCalendarHost()` (`:251-298`).

- [ ] **Step 2: Extend `onChannelEnabled`/`onChannelDisabled`** dispatch for the `calendar` prefix → `initCalendarFn`/`stopSyncFn` via the calendar host, acting on returned descriptors with `this.callback`/`this.runTask`/`this.scheduleRecurring`. Mirror `google.ts:calendarInit` (`:342-368`) and `calendarScheduleWatchRenewal` (`:436-460`).

- [ ] **Step 3: Add Calendar callback methods** invoked by the runtime — `calendarInit`/`initCalendar`, `calendarSyncBatch`/`syncOutlookBatch`, `renewOutlookWatch`, `onOutlookWebhook`, `startIncrementalSync` — as descriptor-driven delegations. Use `scheduleRecurring("calendar:watch-renewal:<id>", …)` with `cancelScheduledTask` on disable.

- [ ] **Step 4: Build.**
Run: `cd public/connectors/outlook && pnpm exec tsc --noEmit && pnpm exec plot lint`
Expected: clean.

- [ ] **Step 5: Commit.**
```bash
cd public && git add connectors/outlook/src/outlook.ts
git commit -m "feat(outlook): Calendar product wiring (init, batch sync, watch renewal)"
```

---

## Phase F — Composite class: Contacts + enrichment gating

### Task F1: Contacts dispatch + Mail enrichment scope gating

**Files:**
- Modify: `public/connectors/outlook/src/outlook.ts`; possibly `public/connectors/outlook-mail/src/sync.ts` (ensure the enrichment call reads `token.scopes` so it degrades when contacts scope absent)

- [ ] **Step 1: Dispatch the `contacts` prefix** in `onChannelEnabled`/`onChannelDisabled` to no-ops (the synthetic `contacts:contacts` channel toggles only the scope intent). Add a short comment explaining there is no import.

- [ ] **Step 2: Confirm Mail enrichment is scope-gated.** In `outlook-mail/src/sync.ts`, verify the enrichment path calls `enrichLinkContactsFromOutlook(links, token, token.scopes)` and that `enrich.ts` already no-ops when `people.read`/`contacts.read` are absent (it does — README documents graceful degrade). If the current code unconditionally enriches, gate it on `token.scopes` containing the contacts scopes.

- [ ] **Step 3: Write a unit test** `outlook-mail/src/enrich.test.ts` (extend existing) asserting `enrichLinkContactsFromOutlook` returns links unchanged and throws nothing when `scopes` excludes the people/contacts scopes.
```ts
it("no-ops when contacts scopes are absent", async () => {
  const links = [/* minimal NewLinkWithNotes fixture */];
  const out = await enrichLinkContactsFromOutlook(links, { token: "t", scopes: ["https://graph.microsoft.com/mail.readwrite"] } as any, ["https://graph.microsoft.com/mail.readwrite"]);
  expect(out).toEqual(links);
});
```

- [ ] **Step 4: Run + build.**
Run: `cd public/connectors/outlook-mail && pnpm exec vitest run && pnpm exec tsc --noEmit`
Run: `cd ../outlook && pnpm exec tsc --noEmit`
Expected: PASS / clean.

- [ ] **Step 5: Commit.**
```bash
cd public && git add connectors/outlook/src/outlook.ts connectors/outlook-mail/src/sync.ts connectors/outlook-mail/src/enrich.test.ts
git commit -m "feat(outlook): Contacts product gating + Mail enrichment scope guard"
```

---

## Phase G — Composite write-back routing

### Task G1: onCreateLink / onNoteCreated / onNoteUpdated / onThreadRead → Mail; RSVP → Calendar

**Files:**
- Modify: `public/connectors/outlook/src/outlook.ts`
- Reference: `google.ts` write-back section (`:813-832`).

- [ ] **Step 1: Implement `override async onCreateLink(draft)`** → route to Mail (`onCreateLinkFn(this.makeMailHost(), draft)`); the `email` link type owns `compose.targets: "addresses"`. Calendar has no compose; return null for non-mail types. Use `resolveProductForLinkType` to confirm routing.

- [ ] **Step 2: Implement `onNoteCreated`/`onNoteUpdated`/`onThreadRead`/`onThreadToDo`** → Mail host delegations (mirror the standalone class). Guard: dispatch only if the Mail product is enabled (scope present + ≥1 mail channel) — reuse `computeProductStatus` inputs or check the channel namespace on the thread/link.

- [ ] **Step 3: Implement `override async onScheduleContactUpdated(...)`** (RSVP) → Calendar host (`onScheduleContactUpdatedFn(this.makeCalendarHost(), …)`). Guard on Calendar enabled.

- [ ] **Step 4: Implement `override async downloadAttachment(ref)`** → Mail host (`downloadAttachmentFn`).

- [ ] **Step 5: Build + lint.**
Run: `cd public/connectors/outlook && pnpm exec tsc --noEmit && pnpm exec plot lint`
Expected: clean.

- [ ] **Step 6: Commit.**
```bash
cd public && git add connectors/outlook/src/outlook.ts
git commit -m "feat(outlook): write-back routing (compose/notes/read to Mail, RSVP to Calendar)"
```

---

## Phase H — Composite integration tests

### Task H1: Dispatch + composition tests

**Files:**
- Create: `public/connectors/outlook/test/outlook.test.ts`

- [ ] **Step 1: Write tests** asserting, with fake products injected where the pure functions allow:
  - `composeChannels` includes only products whose `requiredScopes ⊆ token.scopes`, and namespaces ids `mail:` / `calendar:` / `contacts:`.
  - `resolveProductForChannelId("calendar:AAMk…")` → calendar product; `resolveProductForLinkType("event")` → calendar; `("email")` → mail.
  - `computeProductStatus` with only mail+contacts scopes granted reports calendar `scope-missing`, mail `granted` (≥1 channel), contacts `granted` (channelless/synthetic ≥1).
```ts
import { describe, it, expect } from "vitest";
import { composeChannels, resolveProductForLinkType } from "../src/compose";
import { PRODUCTS_BY_KEY } from "../src/products/product";
// …construct a fake AuthToken with a scope subset and assert namespacing + gating…
```

- [ ] **Step 2: Run.**
Run: `cd public/connectors/outlook && pnpm exec vitest run`
Expected: all PASS.

- [ ] **Step 3: Commit.**
```bash
cd public && git add connectors/outlook/test/outlook.test.ts
git commit -m "test(outlook): composition, routing, and product-status integration tests"
```

---

## Phase I — Site entry, README, final gates

### Task I1: README + apps/site registry entry

**Files:**
- Create: `public/connectors/outlook/README.md`
- Modify: `apps/site/app/data/connections.ts` (this is in the MAIN repo, not the submodule — separate commit/PR)

- [ ] **Step 1: Write `README.md`** (mirror `google/README.md`): one paragraph describing the combined Mail/Calendar/Contacts connection with per-product scope groups.

- [ ] **Step 2: Add the site entry** to `apps/site/app/data/connections.ts`. Confirm the entry type's fields by reading existing entries; mirror the existing "Outlook Mail" entry's `si(...)` logo helper:
```ts
{
  name: "Outlook",
  description: "Send and reply to Outlook email, see your calendar and respond to invites.",
  ...si("microsoftoutlook", "0078D4", "47A5ED"),
  category: "Productivity",
  entities: ["Emails", "Events", "Contacts"],
  available: false,
}
```
(If the entry type supports a `filterText`/aliases field, add `["outlook","mail","email","calendar","microsoft","365","contacts"]`; otherwise omit — match the existing schema exactly.)

- [ ] **Step 3: Leave deploy.json untouched** (review-only). Verify `@plotday/connector-outlook` is NOT in `connectors/deploy.json` `public`.

- [ ] **Step 4: Commit (two commits, two repos).**
```bash
cd public && git add connectors/outlook/README.md && git commit -m "docs(outlook): connector README"
cd .. && git add apps/site/app/data/connections.ts && git commit -m "feat(site): gated Outlook composite connection entry"
```

### Task I2: Full repo-wide gates

- [ ] **Step 1: Build all three connector packages.**
Run:
```bash
cd public/connectors/outlook-mail && pnpm build && pnpm exec vitest run
cd ../outlook-calendar && pnpm build
cd ../outlook && pnpm build && pnpm exec vitest run
```
Expected: all build + tests green.

- [ ] **Step 2: Lint.**
Run: `cd public/connectors/outlook && pnpm exec plot lint` (repeat for outlook-mail, outlook-calendar)
Expected: clean.

- [ ] **Step 3: Run `/finalize`** (repo finalization checklist): lint, backwards-compat (old clients/connectors unaffected — standalone connectors unchanged), error capture (any new catch → `captureException`/`tracker.captureException`), docs fragment via `pnpm updates:new` only if user-facing now (it is gated/not live → likely skip), public submodule PR note.

- [ ] **Step 4: Open the public submodule PR and the main-repo PR** (do NOT deploy; review-only). Confirm no changeset is needed (changesets are only for `twister/` — this is connectors only; per `public/AGENTS.md`, never add a connector-only changeset).

---

## Self-review notes (coverage map)

- Spec §1.1 composite package → Tasks C1–C3, D1, E1, F1, G1.
- Spec §1.2 outlook-mail refactor → Tasks A1–A2.
- Spec §1.3 outlook-calendar refactor → Tasks B1–B2.
- Spec §2.3 scope split (contacts out of Mail) → Task C2 + F1 (gating).
- Spec §2.4 namespacing/composition → Task C1 (copied compose) + H1 tests.
- Spec §2.5 composite class / hosts / dispatch / contacts no-op → D1, E1, F1, G1.
- Spec §2.6 dynamic linkTypes / agenda → D1 (`dynamicLinkTypes = true`) + B1 (`includesSchedules` preserved).
- Spec §3.1 source-key continuity → Global Constraint, preserved by A2/B2 extraction.
- Spec §4 site entry + deploy gating → Task I1.
- Spec §5 testing → C2/C3/H1 + preserved A2 regression suite + F1 enrichment test.
- Spec "out of scope" (To-Do, cutover, core changes, contacts import) → not in any task (correct).
