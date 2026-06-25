# Phase 2 — GoogleConnector core (Calendar wired end-to-end) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single combined `Google` connector package that owns one OAuth/charge and reuses the existing per-product Google connector code, with Calendar wired end-to-end (channels, sync, watch, RSVP write-back) demuxed by product, and per-channel link types attached so dynamic link types (Phase 1) gate the agenda.

**Architecture:** `Google extends Connector<Google>` is an ordinary connector (one `twist_instance`, `AuthProvider.Google`, root OAuth/token/`saveLink`). It declares `dynamicLinkTypes = true` and `scopes: ScopeConfig` with one `OptionalScopeGroup` per product. Each product's logic lives in a connector-private module (`products/calendar.ts`, …) that wraps the **existing** api/sync code from the standalone connectors. The connector's lifecycle methods are thin coordinators that namespace channel ids as `"<productKey>:<rawId>"`, attach each product's link types to its channels, and demux write-backs/sync-continuations by the namespaced id (with `link.type` as a disjoint fallback). Channel-id namespacing is a two-function connector-private convention (`namespace`/`parse`), not an SDK export.

**Tech Stack:** TypeScript, `@plotday/twister` (workspace), vitest. Package at `public/connectors/google/`. Reuses `@plotday/connector-google-calendar`, `-gmail`, `-google-tasks`, `-google-contacts` modules.

## Global Constraints

- **Phase 2 wires Calendar end-to-end ONLY.** Mail/Tasks/Contacts re-homing is Phase 3. Their product modules may be stubbed (channels + scope gating) but full sync/write-back is out of scope here.
- `dynamicLinkTypes = true` AND every channel returned by `getChannels` carries per-channel `linkTypes` for its product. (Required by both the `user.twist` view and the second reader `propagateLinkStatusTagsFromDb` in `link-tags.ts` — a channel with no `linkTypes` falls back to the full static union.)
- Channel ids are **always** `"<productKey>:<rawId>"`; `title` is the un-prefixed display name. Namespacing/parsing lives in exactly one file (`product-channel.ts`) with round-trip tests.
- `scopes = { required: [], optional: [mailGroup, calendarGroup, tasksGroup, contactsGroup] }`. Each group `id` equals the corresponding `products[].scopeGroupId` AND the channel-id prefix (`mail`, `calendar`, `tasks`, `contacts`).
- Product keys (stable): `mail`, `calendar`, `tasks`, `contacts`. Calendar link type `event` has `includesSchedules: true` (drives agenda gating).
- Token refresh stays on the root via `this.tools.integrations.get(channelId)` — no per-product token management, no child tools.
- Reuse existing api/sync code; do **not** fork it. Import from the existing connector packages.
- vitest only; connector-internal tests live in the package. Never touch the DB from this package.
- Generate a fresh `plotTwistId` UUID for the package; mark it `TODO: confirm before catalog cutover (Phase 4)`.

## File Structure

```
public/connectors/google/
  package.json              # @plotday/connector-google, plotTwistId, deps on the 4 product pkgs + twister
  tsconfig.json             # extends @plotday/twister/tsconfig.base.json
  vitest.config.ts          # resolve.conditions: ["@plotday/connector","default"]
  README.md
  src/
    index.ts                # export { default, Google } from "./google";
    google.ts               # Google extends Connector<Google> — thin coordinator
    product-channel.ts      # namespace(product,id) / parse(nsId) / productKeyOf — the ONLY namespacing
    products/
      product.ts            # Product interface + registry (key, scopeGroup, requiredScopes, linkTypes, getChannels, onEnable, onDisable, write-back demux hooks)
      calendar.ts           # wraps @plotday/connector-google-calendar (GoogleApi + sync) — FULL
      mail.ts               # wraps gmail — channels + scope gating only (Phase 3 finishes sync)
      tasks.ts              # wraps google-tasks — channels + scope gating only (Phase 3)
      contacts.ts           # wraps google-contacts — single channel "contacts:contacts" (Phase 3)
    scopes.ts               # the 4 OptionalScopeGroups + products[] metadata array
  test/
    product-channel.test.ts # namespace/parse round-trip, productKeyOf
    scopes.test.ts          # group ids == product keys == channel prefixes; calendar required scope present
    google.getChannels.test.ts   # scope gating (product hidden when required scope absent); id prefixing; linkTypes attached
    google.demux.test.ts    # onChannelEnabled/Disabled route by prefix; write-back routes by thread.meta.channelId; link.type fallback
    google.calendar.test.ts # calendar channels listed + enabled drives sync init; RSVP write-back reaches calendar module
```

---

### Task 1: Scaffold the `google` connector package

**Files:**
- Create: `public/connectors/google/package.json`, `tsconfig.json`, `vitest.config.ts`, `README.md`
- Create: `public/connectors/google/src/index.ts`, `src/google.ts` (minimal compilable skeleton)

**Interfaces:**
- Produces: `Google` class extending `Connector<Google>` with `provider = AuthProvider.Google`, `dynamicLinkTypes = true`, placeholder `scopes`, and stub `getChannels`/`onChannelEnabled`/`onChannelDisabled` (return `[]` / no-op). Compiles and exports.

- [ ] **Step 1: `package.json`** — `name: "@plotday/connector-google"`, `private: true`, fresh `plotTwistId` (`uuidgen`; comment `TODO confirm before Phase 4 cutover`), `displayName: "Google Mail, Calendar, and Tasks"`, `category`, `logoUrl`. `dependencies`: `@plotday/twister: workspace:^`, `@plotday/connector-google-calendar: workspace:^`, `-gmail`, `-google-tasks`, `-google-contacts` (all `workspace:^`). `devDependencies`: typescript, vitest. `exports` block with the `@plotday/connector` condition pointing at `./src/index.ts` (copy Gmail's package.json shape exactly).
- [ ] **Step 2: `tsconfig.json` + `vitest.config.ts`** — copy from `public/connectors/gmail/` (vitest `resolve.conditions: ["@plotday/connector","default"]`).
- [ ] **Step 3: `src/google.ts` skeleton** — class with the identity fields + stub methods; `src/index.ts` re-export.
- [ ] **Step 4:** `cd public && pnpm install` then `cd connectors/google && pnpm exec tsc --noEmit`. Expected: compiles clean.
- [ ] **Step 5: Commit** `feat(connector-google): scaffold combined Google connector package`.

### Task 2: Channel-id namespacing (`product-channel.ts`)

**Files:**
- Create: `public/connectors/google/src/product-channel.ts`, `test/product-channel.test.ts`

**Interfaces:**
- Produces: `namespace(product: string, rawId: string): string` (`"calendar" + "primary" → "calendar:primary"`); `parse(nsId: string): { product: string; rawId: string }` (splits on the FIRST `:`; `rawId` may itself contain `:`); `productKeyOf(nsId: string): string | null` (prefix before first `:`, or null if none). Mirrors the Dart `productKeyOf` in `apps/plot/lib/util/product_channel.dart`.

- [ ] **Step 1: Write failing tests** — round-trip `parse(namespace(p,id)) == {p,id}` for ids containing `:` (e.g. `mail:Label_42:x`); `productKeyOf("calendar:primary") == "calendar"`; `productKeyOf("noprefix") == null`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the three pure functions (split on first `:` only).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(connector-google): product channel-id namespacing`.

### Task 3: Scopes + products metadata (`scopes.ts`)

**Files:**
- Create: `public/connectors/google/src/scopes.ts`, `test/scopes.test.ts`
- Reference: existing scope constants — `GoogleCalendar.EVENTS_SCOPE`/`CALENDAR_LIST_SCOPE`, `Gmail.SCOPES`, `GoogleTasks.SCOPES`, `GOOGLE_PEOPLE_SCOPES`.

**Interfaces:**
- Produces: `OPTIONAL_SCOPE_GROUPS: OptionalScopeGroup[]` (one per product, `id ∈ {mail,calendar,tasks,contacts}`, `default: true`, `scopes` = that product's required scopes); `PRODUCTS: ProductInfo[]` (`{key,label,description,icon,scopeGroupId}` matching the frozen contract §4.2, `key===scopeGroupId`); a `GOOGLE_SCOPES: ScopeConfig = { required: [], optional: OPTIONAL_SCOPE_GROUPS }`.

- [ ] **Step 1: Write failing tests** — every group `id` is in `{mail,calendar,tasks,contacts}` and unique; each `PRODUCTS[i].scopeGroupId === PRODUCTS[i].key` and matches a group id; calendar group includes `calendar.events`; contacts group includes the People scopes.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** `scopes.ts` importing the scope constants from the product packages.
- [ ] **Step 4: Run, verify pass.** Wire `readonly scopes = GOOGLE_SCOPES` into `google.ts`.
- [ ] **Step 5: Commit** `feat(connector-google): per-product optional scope groups + products metadata`.

### Task 4: Product interface + registry (`products/product.ts`)

**Files:**
- Create: `public/connectors/google/src/products/product.ts`

**Interfaces:**
- Produces: a `Product` interface —
  ```ts
  interface Product {
    key: "mail" | "calendar" | "tasks" | "contacts";
    requiredScopes: string[];        // ⊆ token.scopes ⇒ available
    linkTypes: LinkTypeConfig[];     // attached to each of this product's channels
    channelless?: boolean;           // contacts: exactly one synthetic channel
    getRawChannels(token: AuthToken, tools): Promise<Channel[]>;  // un-prefixed ids
    onEnable(rawChannelId: string, tools, context?): Promise<void>;
    onDisable(rawChannelId: string): Promise<void>;
    // write-back demux hooks (optional per product) — bare rawChannelId
    onNoteCreated?, onLinkUpdated?, onCreateLink?, onThreadRead?, onThreadToDo?,
    onScheduleContactUpdated?, onContactsChanged?, onNoteReactionChanged?
  }
  ```
  plus `PRODUCTS_BY_KEY: Record<string, Product>` registry (populated as modules land).
- Consumes: the `Channel`, `AuthToken`, `LinkTypeConfig` types from `@plotday/twister`.

- [ ] **Step 1:** Define the interface + an empty registry object; export both. (No behavior yet — type-only foundation, so no test beyond `tsc`.)
- [ ] **Step 2:** `pnpm exec tsc --noEmit` clean.
- [ ] **Step 3: Commit** `feat(connector-google): product module interface + registry`.

### Task 5: `getChannels` composition (scope-gated, prefixed, link-typed)

**Files:**
- Modify: `public/connectors/google/src/google.ts`
- Create: `public/connectors/google/test/google.getChannels.test.ts`

**Interfaces:**
- Consumes: `PRODUCTS_BY_KEY` (Task 4), `namespace` (Task 2).
- Produces: `Google.getChannels(auth, token)` — for each registered product whose `requiredScopes ⊆ token.scopes`, call `product.getRawChannels`, prefix each id (recursively for `children`) via `namespace(product.key, rawId)`, attach `product.linkTypes` to each channel, concatenate. Channelless products contribute exactly one channel.

- [ ] **Step 1: Write failing tests** with a fake token + fake product registry: a product whose required scope is absent from `token.scopes` contributes NO channels; present → its channels appear with `"<key>:"`-prefixed ids, un-prefixed `title`, and `channel.linkTypes` set; nested `children` ids are prefixed too.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the composition loop in `getChannels`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(connector-google): scope-gated, namespaced, link-typed getChannels`.

### Task 6: Enable/disable + write-back demux

**Files:**
- Modify: `public/connectors/google/src/google.ts`
- Create: `public/connectors/google/test/google.demux.test.ts`

**Interfaces:**
- Consumes: `parse`/`productKeyOf` (Task 2), `PRODUCTS_BY_KEY` (Task 4).
- Produces: `onChannelEnabled(channel)`/`onChannelDisabled(channel)` parse the prefix and dispatch to `product.onEnable/onDisable(rawId, …)`. Each write-back (`onNoteCreated`, `onLinkUpdated`, `onCreateLink`, `onThreadRead`, `onThreadToDo`, `onScheduleContactUpdated`, `onContactsChanged`) resolves the owning product by the namespaced id on `thread.meta.channelId` / `link.channelId` / `draft.channelId`; if absent, fall back to the product whose `linkTypes` contains `link.type` (disjoint per product). Unknown/no-match → no-op (logged).

- [ ] **Step 1: Write failing tests** — `onChannelEnabled({id:"calendar:primary"})` calls the calendar module's `onEnable("primary")` and not mail's; a write-back with `thread.meta.channelId="calendar:x"` reaches calendar; one with only `link.type="event"` (no channelId) also reaches calendar via fallback; `link.type="task"` reaches tasks.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the demux helpers + wire each callback.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(connector-google): product demux for enable/disable + write-backs`.

### Task 7: Calendar product module — channels + link types (reuse google-calendar)

**Files:**
- Create: `public/connectors/google/src/products/calendar.ts`
- Modify: `products/product.ts` registry to include calendar
- Create/extend: `public/connectors/google/test/google.calendar.test.ts`

**Interfaces:**
- Consumes: `@plotday/connector-google-calendar` (`GoogleApi`, its calendar-list + channel logic), the `event` `LinkTypeConfig` (with `includesSchedules: true`).
- Produces: `calendarProduct: Product` with `key:"calendar"`, `requiredScopes:[EVENTS_SCOPE]`, `linkTypes:[event]`, `getRawChannels` (delegates to the existing calendar-list logic, un-prefixed ids), `onEnable` (kicks the existing `initCalendar`/`syncCalendarBatch` path), `onDisable`.

- [ ] **Step 1: Write failing tests** — calendar `getRawChannels` returns calendars with `enabledByDefault` mirroring owner role; the product's `linkTypes[0].includesSchedules === true`; `onEnable` invokes the calendar sync entry.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** by importing and delegating to the existing google-calendar code (do NOT reimplement). Where the existing code is a connector method, extract the minimal reusable function or call through a thin adapter — keep the existing connector's behavior identical.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(connector-google): calendar product — channels, link types, enable`.

### Task 8: Calendar sync continuations + watch + RSVP write-back demux

**Files:**
- Modify: `products/calendar.ts`, `src/google.ts` (callback methods carrying the product key in args)
- Extend: `test/google.calendar.test.ts`

**Interfaces:**
- Produces: the connector's `syncBatch`/`renewWatch`/`onWebhook` callbacks carry/derive the product key and dispatch to the calendar module; state keys are product-prefixed (`calendar:sync_state:<id>`); `onScheduleContactUpdated` (RSVP) routes to calendar by namespaced channel id. Watch registration/renewal reuses the existing `setupCalendarWatch`/`renewWatch`.

- [ ] **Step 1: Write failing tests** — a sync continuation tagged `calendar` re-enters the calendar module with the bare calendar id; `onScheduleContactUpdated` for a `calendar:`-namespaced thread reaches the calendar RSVP path; sync-state keys are product-prefixed.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the product-keyed callback dispatch + state-key prefixing, delegating to existing calendar sync/watch code.
- [ ] **Step 4: Run, verify pass.** `pnpm exec tsc --noEmit` + `pnpm test` clean for the package.
- [ ] **Step 5: Commit** `feat(connector-google): calendar sync continuations, watch, RSVP demux (e2e)`.

### Task 9: Mail/Tasks/Contacts product stubs (channels + scope gating only)

**Files:**
- Create: `products/mail.ts`, `products/tasks.ts`, `products/contacts.ts`; register all in `products/product.ts`
- Extend: `test/google.getChannels.test.ts`

**Interfaces:**
- Produces: each as a `Product` with correct `key`, `requiredScopes`, `linkTypes`, and `getRawChannels` delegating to the existing connector's channel logic (contacts = single `"contacts"` channel, `channelless: true`). `onEnable`/`onDisable` may throw `NotImplemented` (Phase 3 wires sync) — clearly commented. This lets the full product list + scope gating + status render now.

- [ ] **Step 1: Write failing tests** — with all four scopes granted, `getChannels` includes channels for all four products with correct prefixes + link types; with only `calendar.events`, only calendar channels appear.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the three stub modules (channels + link types real; sync/write-back deferred with explicit `Phase 3` TODOs).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(connector-google): mail/tasks/contacts channel listing + scope gating (sync deferred to Phase 3)`.

---

## Self-review checklist (run before declaring Phase 2 done)
- Every channel from `getChannels` has `linkTypes` (else the `link-tags.ts` reader uses the static union).
- `namespace`/`parse` are the only place ids are split/joined; grep the package for stray `:` splitting.
- Calendar works end-to-end against the existing google-calendar code with its tests still green.
- Mail/Tasks/Contacts are stubbed but render in the product list + gate by scope.
- `dynamicLinkTypes = true` and `scopes` group ids === product keys === channel prefixes === `products[].scopeGroupId`.
- Package `tsc --noEmit` + `vitest` clean. No DB access from this package.

## What Phase 2 deliberately defers
- Mail/Tasks/Contacts **sync + write-back** re-homing → **Phase 3** (the high-fidelity work: Gmail Pub/Sub, Tasks polling, Contacts enrichment).
- `products`/`productStatus` **API endpoints** + the enablement predicate exposed over HTTP → **Phase 4** (the connector computes status internally here; the endpoint surfaces it there).
- Catalog cutover (one source replaces three) → **Phase 4**. Bankruptcy migration → **Phase 6**.
