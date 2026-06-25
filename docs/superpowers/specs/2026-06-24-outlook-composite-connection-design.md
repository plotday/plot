# Outlook Mail + Calendar — single connection + composite-connector (the Microsoft consumer)

**Date:** 2026-06-24
**Status:** Design (approved in brainstorming; pending spec review)
**Author:** Kris Braun (with Claude)

## Problem

Today Outlook Mail and Outlook Calendar are two separate **connectors** with their own
`twist_instance`, their own OAuth consent, and their own charge — even though both
authenticate against the **same Microsoft account** via `AuthProvider.Microsoft`.
Connecting both means two picker entries, two OAuth round-trips, and two "connections,"
which is the same onboarding friction the Google composite was built to remove.

The Google composite connector (`public/connectors/google/`) was deliberately designed to
be **provider-agnostic, with Microsoft as the next consumer** (see
`2026-06-22-google-composite-connection-design.md` §2.4 and "Provider-agnostic check").
This spec is that next consumer: one **"Outlook"** connection bundling **Mail, Calendar,
and Contacts** under one Microsoft OAuth consent and one charge, internally modular and
maintainable, reusing the Google composite's pattern verbatim.

## Goals

- A single connection — **"Outlook"** — bundling **Mail, Calendar, and Contacts** as
  products under **one Microsoft OAuth consent** and **one charge**.
- Searching any product term (`outlook`, `mail`, `email`, `calendar`, `microsoft`, `365`,
  `contacts`, …) surfaces the one connection.
- **No double-toggling of products.** No Plot-side product toggles before auth — the user
  chooses once on Microsoft's consent screen. Plot requests the union of product scopes;
  Microsoft's incremental/granular consent is the chooser.
- After auth, **clearly show which products are enabled vs. not**, derived from the scopes
  actually granted (the existing provider-agnostic `productStatus` machinery).
- **Re-auth at any time** to add a product's permission — a single OAuth attempt can add
  several at once (the existing `enabledScopeGroups` incremental flow).
- **Agenda gating stays permission-aware**: the agenda appears only when the Calendar
  product is enabled, driven by the composite's effective (dynamic) `linkTypes`.
- A maintainable architecture: independent product modules behind one connection, reusing
  the exact pattern already proven for Google.

## Non-goals

- **Microsoft To-Do.** No Microsoft To-Do connector exists; a To-Do product is net-new work
  and is out of scope. (Google's composite has a Tasks product because `google-tasks` exists.)
- **Production cutover / "bankruptcy"** of existing Outlook Mail / Outlook Calendar
  connections (archive old instances + reconnect prompt). Deferred to a later manual
  ops runbook, exactly like Google. This effort ships the connector to the **review**
  environment (not the public deploy list) and a **gated** site entry.
- **Any core Flutter / API / twister / DB change.** Verified unnecessary — see "Provider
  agnosticism (verified)" below. The only change outside the connector packages is one
  manually-curated `apps/site` registry entry.
- **Microsoft Contacts import.** Outlook has no contacts-import connector; the Contacts
  product gates the existing *enrichment* scopes only (see §3). It does not import contacts
  as threads/links the way Google's Contacts product does.

## Terminology

- **Product** — a user-facing capability area within the connection (Mail, Calendar,
  Contacts). Maps to one optional scope group and (for channel-bearing products) a set of
  channels.
- **Product module** — the code unit implementing one product. In the composite it is a
  `Product` record (`products/*.ts`) that wraps the underlying connector's exported
  `channels.ts` / `sync.ts` pieces.
- **Composite connector** — a single `Connector` (one `twist_instance`, one OAuth, one
  charge) composing several product modules. Exposed in the app as one connection.

---

## Provider agnosticism (verified)

A codebase audit confirmed the supporting machinery is fully provider-agnostic; the Google
composite's `plotTwistId` (`6e9e441f-…`) appears **nowhere** outside its own `package.json`.
The following already work for any `AuthProvider`, including `Microsoft`, with **no change**:

| Component | Location | Status |
|---|---|---|
| Flutter product setup / status / refine UI | `apps/plot/lib/widget/product_setup.dart`, `setup_source.dart`, `apps/plot/lib/util/product_channel.dart` | ✅ generic, data-driven |
| `ProductInfo` / `ProductStatus` models | `apps/plot/lib/api/twist_api.dart` | ✅ generic |
| API product-status derivation | `workers/api/src/app/product-status.ts`, `twist-integrations.ts` | ✅ generic |
| Optional scope groups + incremental re-auth (`enabledScopeGroups`, `getAuthUrl`) | `workers/api/src/twist/tools/auth-scope.ts`, `apps/plot/lib/command/twist.dart` | ✅ generic |
| Agenda gating (`linkTypesIncludeSchedules`, `hasCalendarConnectionInCache`) | `apps/plot/lib/store/twist_instance.dart` | ✅ driven by `includesSchedules` link-type flag |
| `seed_default_channels` reconnect auto-enable | `workers/api/src/twist/tools/integrations.ts`, DB column | ✅ generic owned-channel seeder |
| `AuthProvider.Microsoft` + OAuth config | `public/twister/src/tools/integrations.ts`, `workers/api/src/provider.ts` | ✅ already wired (authUrl/tokenUrl/parse, incremental consent) |

**Only manual change outside the connector packages:** add an `apps/site/app/data/connections.ts`
entry (the site registry is hand-curated, not derived from connector metadata).

---

## Part 1 — Package structure

### 1.1 New composite package — `public/connectors/outlook/`

Mirrors `public/connectors/google/` one-to-one.

```
public/connectors/outlook/
  package.json        name "@plotday/connector-outlook"; NEW plotTwistId; displayName "Outlook";
                      description "Email, calendar, and contacts from your Outlook account.";
                      category "messaging"; logoUrl microsoftoutlook;
                      deps: @plotday/connector-outlook-mail, @plotday/connector-outlook-calendar,
                            @plotday/twister  (all workspace:^)
  tsconfig.json       extends @plotday/twister/tsconfig.base.json
  vitest.config.ts
  README.md
  src/
    index.ts          export { default, Outlook } from "./outlook";
    outlook.ts        composite Connector<Outlook> (the big file; mirrors google.ts)
    scopes.ts         OUTLOOK_SCOPES: ScopeConfig + PRODUCTS: ProductInfo[]
    compose.ts        composeChannels / resolveProductForChannelId / resolveProductForLinkType
    product-channel.ts  namespace / parse / productKeyOf      (copy from google, verbatim)
    product-status.ts   computeProductStatus + types          (copy from google, verbatim)
    products/
      product.ts      Product interface + PRODUCTS_BY_KEY  (keys "mail" | "calendar" | "contacts")
      mail.ts         mailProduct       → wraps outlook-mail channels/sync exports
      calendar.ts     calendarProduct   → wraps outlook-calendar channels/sync exports
      contacts.ts     contactsProduct   → channelless; gates enrichment scopes
  test/
    scopes.test.ts          three-way invariant (group id == key == prefix); PRODUCTS metadata
    compose.test.ts         scope-gating, namespacing (incl. recursive children), resolvers
    product-status.test.ts  granted / scope-missing / locally-off / no-channels (+ channelless)
    product-channel.test.ts namespace/parse/productKeyOf round-trips
```

`product-channel.ts` and `product-status.ts` are copied verbatim from the Google package
(they are pure, provider-agnostic helpers). `compose.ts` is copied with no Google-specific
content. The Dart-side mirror `apps/plot/lib/util/product_channel.dart` already parses the
generic `<product>:<rawId>` form and needs no change.

### 1.2 Refactor `public/connectors/outlook-mail/` (extract, keep class working)

The same split that `gmail/` received (`gmail/src/{channels.ts, sync.ts}` + a thin
`gmail.ts`). Today `outlook-mail.ts` is one ~1850-line class. After:

```
public/connectors/outlook-mail/src/
  channels.ts       NEW. getOutlookMailChannels(token): Promise<Channel[]>;
                    OUTLOOK_MAIL_SCOPES (mail.readwrite, mail.send);
                    OUTLOOK_MAIL_LINK_TYPES (the existing "email" link type).
  sync.ts           NEW. OutlookMailSyncHost interface + host-pattern functions:
                    initial/incremental sync batch, mailbox subscription setup/renew/teardown,
                    self-heal check, onCreateLink, onNoteCreated/onNoteUpdated, onThreadRead,
                    attachment download, enabled-channel tracking, and the enrichment hook
                    (calls enrich.ts's enrichLinkContactsFromOutlook with the granted scopes).
  outlook-mail.ts   OutlookMail extends Connector — becomes a THIN driver that constructs a
                    self-host ({ set/get/clear → this.set/get/clear, tools → this.tools }) and
                    delegates to sync.ts. Still a deployable standalone connector.
  graph-mail-api.ts, email-parsing.ts, outlook-facets.ts, enrich.ts — unchanged.
  index.ts          re-exports { default, OutlookMail } AND the channels.ts + sync.ts surface
                    the composite imports (mirror gmail/src/index.ts).
```

### 1.3 Refactor `public/connectors/outlook-calendar/` (same treatment)

Mirrors `google-calendar/src/{channels.ts, sync.ts}`.

```
public/connectors/outlook-calendar/src/
  channels.ts       NEW. getOutlookCalendarChannels(token): Promise<Channel[]>;
                    OUTLOOK_CALENDAR_SCOPE (calendars.readwrite);
                    OUTLOOK_CALENDAR_LINK_TYPES (the existing "event" link type,
                    includesSchedules: true).
  sync.ts           NEW. OutlookCalendarSyncHost + host-pattern functions: two-pass init
                    (quick + full), batch sync, recurring-occurrence buffering (pending_occ /
                    seen_master), watch setup/stop, watch-renewal schedule, webhook validation,
                    incremental sync start, RSVP write-back (extract + apply).
  outlook-calendar.ts  OutlookCalendar becomes a thin driver over sync.ts via a self-host.
  graph-api.ts      unchanged.
  index.ts          re-exports class + channels/sync surface (mirror google-calendar/src/index.ts).
```

The refactor is mechanical-but-careful: move connector-instance-bound orchestration into
functions that take a host; replace `this.set/get/clear/acquireLock/list` with `host.*`;
replace `this.callback/runTask/scheduleRecurring` calls by having the host's owner (the
connector) keep the scheduling and pass the host into the pure logic. The existing
`graph-*.ts` API clients and transforms are already decoupled and move unchanged.

---

## Part 2 — Architecture

### 2.1 Per-module isolation is automatic (the enabler)

Identical to the Google rationale: the runtime isolates **state** (`Store` keyed
`<twistInstanceId>:<toolPath>`), **scheduled callbacks** (`callbacks.path`), and **webhooks**
(token → `{ twist_instance_id, path, functionName }`) per tool-path. With each product driven
through a key-prefixed host (`mail:`, `calendar:`, `contacts:`), per-product state / scheduled
sync / webhooks don't collide. Billing counts **per `twist_instance` with ≥1 enabled channel**,
so **one composite = one charge** automatically.

### 2.2 `Product` interface + registry (in `outlook/src/products/`)

Copied from Google, with Outlook keys:

```ts
export interface Product {
  key: "mail" | "calendar" | "contacts";
  requiredScopes: string[];
  linkTypes: LinkTypeConfig[];
  channelless?: boolean;                       // contacts: true (one synthetic channel)
  getRawChannels(token: AuthToken): Promise<Channel[]>;
  onEnable(rawChannelId: string, context?: SyncContext): Promise<void>;
  onDisable(rawChannelId: string): Promise<void>;
}
export const PRODUCTS_BY_KEY = { mail, calendar, contacts };
```

As in Google, Mail's and Calendar's `onEnable/onDisable` throw — the composite class
intercepts those prefixes and handles lifecycle directly (it owns the scheduling). Contacts'
`onEnable/onDisable` are no-ops (see §2.5).

### 2.3 Scopes and products metadata (`outlook/src/scopes.ts`)

Three optional scope groups; **three-way invariant** `group.id === product.key === channel prefix`.

```ts
export const OUTLOOK_SCOPES: ScopeConfig = {
  required: [],
  optional: [
    { id: "mail",     label: "Mail",     default: true,
      scopes: ["https://graph.microsoft.com/mail.readwrite",
               "https://graph.microsoft.com/mail.send"] },
    { id: "calendar", label: "Calendar", default: true,
      scopes: ["https://graph.microsoft.com/calendars.readwrite"] },
    { id: "contacts", label: "Contacts", default: true,
      scopes: ["https://graph.microsoft.com/people.read",
               "https://graph.microsoft.com/contacts.read"] },
  ],
};

export const PRODUCTS: ProductInfo[] = [
  { key: "mail",     label: "Outlook Mail",     scopeGroupId: "mail",
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

Per-product `icon` values above are **provisional** — finalize against AGENTS.md
"Connector Icon Guidelines" (verify ~1:1 aspect ratio, dark-mode visibility) during
implementation. Microsoft offers no distinct per-product brand marks, so Mail uses the
Outlook mark and Calendar/Contacts use neutral glyphs.

**Scope split note:** today `outlook-mail` declares its scopes as
`MergeScopes(mail.readwrite + mail.send, OUTLOOK_PEOPLE_SCOPES)`. In the composite the
people/contacts scopes move **out of Mail** into the optional `contacts` group, so the user
can decline enrichment without losing Mail. The standalone `outlook-mail` connector keeps its
current merged scopes unchanged (no behavior change for the standalone path).

### 2.4 Channel composition + namespacing (`outlook/src/compose.ts`)

Verbatim Google logic: for each product whose `requiredScopes ⊆ token.scopes`, call
`getRawChannels(token)`, prefix every channel id (recursively) `"<key>:<rawId>"`, and attach
the product's `linkTypes`. Channel ids: `mail:<folderId>`, `calendar:<calendarId>`,
`contacts:contacts`. First-colon split is safe — Outlook folder/calendar ids contain no `:`,
and mail conversation ids live in `link.source`, never in the channel id.

### 2.5 The composite connector class (`outlook/src/outlook.ts`)

Mirrors `google.ts`. Key declarations:

```ts
export class Outlook extends Connector<Outlook> {
  static readonly handleReplies = true;      // Mail is bidirectional
  readonly provider = AuthProvider.Microsoft;
  readonly dynamicLinkTypes = true;          // effective linkTypes vary by enabled products
  readonly scopes = OUTLOOK_SCOPES;
  readonly products = PRODUCTS;
  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      files: build(Files),                    // Mail attachment download
    };
  }
}
```

- `activate()` stores the connecting actor id under the Mail host (Mail attributes synced
  threads to the account owner — preserve the existing behavior).
- `getChannels()` → `composeChannels(Object.values(PRODUCTS_BY_KEY), token)`.
- `onChannelEnabled/Disabled(channel, ctx)` → `parse(channel.id)`, dispatch by product key to
  per-product handlers; each constructs a key-prefixed host and calls the extracted sync fns.
- **Storage hosts**: `makeMailHost()` / `makeCalendarHost()` prefix keys (`mail:` / `calendar:`)
  and proxy `acquireLock`/`releaseLock`/`list` (stripping the prefix on `list`), exactly like
  Google's host wrappers.
- **Webhooks**: Mail registers one mailbox-wide Graph subscription + hourly self-heal; Calendar
  registers per-calendar watches with 24h-before renewal via `scheduleRecurring`. Inbound hooks
  resolve to the owning product by callback `path`.
- **Write-back routing**:
  - `onCreateLink(draft)` → Mail (the `email` link type declares `compose.targets: "addresses"`;
    Calendar has no compose).
  - `onNoteCreated` / `onNoteUpdated` → Mail.
  - `onThreadRead` → Mail (read/flag write-back).
  - `onScheduleContactUpdated` (RSVP) → Calendar.
  Routing resolves the owning product from the link/channel namespace (or link type via
  `resolveProductForLinkType`), and **must check the product is enabled before dispatching**.
- **Contacts** (`contactsProduct`): `channelless: true`, `linkTypes: []`, one synthetic
  `contacts:contacts` channel. `onEnable`/`onDisable` are no-ops — there is no contacts import.
  Its only effect is the granted `contacts` scope, which Mail's sync reads to run
  `enrichLinkContactsFromOutlook(links, token, token.scopes)`. Contacts-on ⇒ names enriched;
  Contacts-off ⇒ Mail syncs without names (enrichment already degrades gracefully). The
  synthetic channel is "owned," so `seed_default_channels` auto-enables it on reconnect.

### 2.6 Effective link types / agenda gating

`dynamicLinkTypes = true` makes the connection's serialized `linkTypes` the union over
*enabled* products' channels. When Calendar is enabled, its channels carry
`{ type: "event", includesSchedules: true }`, so `linkTypesIncludeSchedules` is true and the
agenda shows; when Calendar is disabled, no event link type and the agenda hides. No gating
call-site changes — identical to Google.

### 2.7 What does not change

- Billing / limits (`getPersonalConnectionCount`) — one composite counts as one.
- Webhook ingestion path, callback DO, `Store` keying — already path-aware.
- Cross-user thread convergence via globally-unique `source` keys (see §3.1).
- The standalone `outlook-mail` / `outlook-calendar` connectors remain deployable and behave
  exactly as today (the refactor is internal; their public class + scopes are unchanged).

---

## Part 3 — Correctness invariants

### 3.1 Source-key continuity (must not change)

The extracted sync functions emit the **identical** `source` strings as the standalone
connectors do today:

- Mail: `outlook-mail:<accountEmail>:<conversationId>` (+ `note.key` = `internetMessageId`).
- Calendar: `outlook-calendar:<calendarId>:<eventId>` plus the `icaluid:<iCalUID>` alias and
  `outlook-event:<eventId>` (for cross-connector bundling with Fellow/Granola).

Preserving these by construction (we move the logic, we do not rewrite the source builders)
guarantees: (a) cross-user dedup keeps converging two users' views of the same item onto one
thread; (b) a **future** cutover that re-syncs from Microsoft upserts onto existing threads
rather than duplicating. Any change to a `source` format is a regression and is out of scope.

### 3.2 `initialSync` propagation

Both products already thread an `initialSync` flag from entry point through every batch
(set `unread:false, archived:false` on initial, omit on incremental). The host-pattern
functions must keep that threading intact (it is preserved by construction).

### 3.3 Callback signature compatibility

The composite's callback methods are new (new connector, new instance ids), so there is no
deployed-callback compatibility constraint from the standalone connectors. Within the
composite, follow the connector rules (append optional params only; serializable tokens, not
functions).

---

## Part 4 — Site registry + deploy gating

- **`apps/site/app/data/connections.ts`**: add one entry, replacing nothing yet (existing
  "Outlook Mail" / "Outlook Calendar" entries are already `available: false`). New entry:

  ```ts
  {
    name: "Outlook",
    description: "Send and reply to Outlook email, see your calendar and respond to invites.",
    ...si("microsoftoutlook", "0078D4", "47A5ED"),
    category: "Productivity",            // same grouping the picker uses for multi-product connections
    entities: ["Emails", "Events", "Contacts"],
    available: false,                    // gated until cutover
    filterText: ["outlook", "mail", "email", "calendar", "microsoft", "365", "contacts"],
  }
  ```

  (Confirm `filterText` is a supported field on the site entry type; if not, fold aliases into
  the existing search mechanism the site uses.)

- **`connectors/deploy.json`**: do **not** add `@plotday/connector-outlook` to the `public`
  list → it deploys to **review** only, exactly like `@plotday/connector-google`. Go-live and
  the production bankruptcy are a later, human-gated step.

---

## Part 5 — Testing strategy

- **Composite scaffolding (pure unit tests):** scope/product three-way invariant, channel
  namespacing + recursive child prefixing, `composeChannels` scope-gating, resolvers,
  `computeProductStatus` including the **channelless Contacts** case (enabled = scope granted +
  not locally-off, no channel required at the connector layer — note the synthetic
  `contacts:contacts` channel exists so the API-side `enabledChannelCount` is ≥1).
- **Refactor regression net:** preserve and keep green `outlook-mail`'s existing test suite
  (`email-parsing.test.ts`, `enrich.test.ts`, `graph-mail-api.test.ts`, `outlook-facets.test.ts`,
  `outlook-mail.test.ts`) through the extraction — they are the guard that the host-pattern
  move didn't change behavior. Add minimal `outlook-calendar` sync tests if the extraction
  exposes easily-unit-testable seams (it currently has none).
- **Enrichment-degradation test:** Mail sync with the `contacts` scope absent produces links
  without enriched names and does not throw.
- **Build gates:** `pnpm build` and `pnpm exec tsc --noEmit` green in `outlook`, `outlook-mail`,
  `outlook-calendar`; `pnpm lint` (`plot lint`) green; root `pnpm install` after adding the new
  package to the workspace.

## Risks & open implementation details (for the plan, not blockers)

- **Extraction surface area.** `outlook-mail.ts` (~1850 lines) and `outlook-calendar.ts`
  (~1630 lines) are large. The host-pattern split must move *all* `this.*` state/lock/list/
  scheduling touchpoints behind the host without altering behavior. The existing mail tests
  are the safety net; calendar has thinner coverage, so extract conservatively and lean on
  `tsc` + `plot lint` + a careful diff.
- **Contacts scope split vs. standalone Mail.** Moving people/contacts into the composite's
  `contacts` group must not change the standalone `outlook-mail` connector's scopes. Keep the
  standalone class's `MergeScopes(..., OUTLOOK_PEOPLE_SCOPES)` as-is; only the composite splits.
- **`channelNoun` for a mixed connection.** Google uses a generic `{channel, channels}` for the
  composite even though Mail is "folders" and Calendar is "calendars." Mirror that; per-product
  channel lists in the refine UI can still read naturally.
- **`autoEnableNewChannelsByDefault`.** Standalone `outlook-calendar` sets this true. Decide
  whether the composite needs an equivalent or whether `seed_default_channels` + owned-default
  selection already covers "new calendars sync automatically" (Google relies on the latter).
- **New `plotTwistId`.** Generate via `plot create --connector` (do not hand-author the UUID).
- **Microsoft incremental consent UX.** Confirm Microsoft's consent surfaces the union of
  three groups and supports incremental add (the OAuth config already exists; the Google flow
  assumes granular consent — Microsoft's behaves analogously but verify during implementation).

## Out of scope (restated)

Microsoft To-Do product; production cutover / bankruptcy of existing Outlook connections;
contacts *import* (vs. enrichment); any core Flutter / API / twister / DB change.
