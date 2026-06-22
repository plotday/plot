# Google Mail, Calendar & Tasks — single connection + composite-connector architecture

**Date:** 2026-06-22
**Status:** Design (approved in brainstorming; pending spec review)
**Author:** Kris Braun (with Claude)

## Problem

Today every Google product is a separate **connector** with its own `twist_instance`,
its own OAuth consent, and its own charge. Connecting Gmail + Calendar + Tasks means
three picker entries, three OAuth round-trips, and three "connections." That is too much
onboarding friction, and the per-product channel toggles compound it (users effectively
choose a product twice — once as a scope, once as channels).

We want **one connection** that covers a user's core Google products, charged once,
but still internally modular and maintainable — and the permission/product machinery must
**not be Google-specific** (Microsoft is the next consumer).

## Goals

- A single connection — **"Google Mail, Calendar, and Tasks"** — bundling **Mail, Calendar,
  Tasks, and Contacts** as products under **one OAuth consent** and **one charge**.
- Searching any product term (`gmail`, `mail`, `calendar`, `tasks`, `contacts`, `google`, …)
  still surfaces the connection.
- **No double-toggling of products.** There are **no Plot-side product toggles before auth** —
  the user chooses once, on Google's consent screen. Granting a product's permission *is*
  enabling it; all products are optional, with clear per-product explanations in setup.
- After auth, **clearly show which products are enabled vs. not**, derived from the
  permissions actually granted.
- **Re-auth at any time** to add product permissions — and a **single OAuth attempt** can add
  several at once (handles the common "forgot to tick the box on Google's screen" mistake).
- **Agenda gating becomes permission-aware**: the agenda shows only when the Calendar product
  is actually enabled on the connection, not merely because the connection exists.
- A **maintainable architecture for mega-connections**: independent product modules behind a
  single connection, **reusable for Microsoft** with no Google-specific permission logic.

## Non-goals

- **Drive and Chat stay as their own separate connections** (as today). They are not part of
  this bundle. This keeps the initial consent lighter and friendlier to Google's OAuth review.
- No seamless data migration. Existing Google connections are handled by **bankruptcy** (below).
- Building the Microsoft composite. We make the abstractions provider-agnostic so Microsoft is
  cheap later, but it is out of scope here.

## Terminology

- **Product** — a user-facing capability area within a connection (Mail, Calendar, Tasks,
  Contacts). Each maps to a scope group and, usually, a set of channels (Contacts has none).
- **Product module** — the code unit implementing one product (channels, link types, sync,
  write-back). Internally a child tool of the composite connector.
- **Composite connector** — a single `Connector` (one `twist_instance`, one OAuth, one charge)
  that composes several product modules. Exposed in the app as one connection.

---

## Part 1 — UX

All screens reuse the **existing `SelectModal` / `EditSource` surface**: same styling, same
up/down cursor navigation between rows, space/enter to toggle. These are new *row types* in the
existing modal, not a new modal pattern. On/off controls are **trailing toggles** (switches),
matching today's channel toggles — Plot has **no leading-checkbox pattern**, so we never use one.

### 1.1 Catalog & search

One catalog entry replaces the three Google product tiles. Drive and Chat keep their own tiles.

- Display name: **"Google Mail, Calendar, and Tasks"** (logo: Google).
- `filterText` aliases: `gmail, mail, email, inbox, calendar, gcal, agenda, tasks, todo,
  to-do, contacts, google, workspace`.
- Searching `drive` / `chat` still matches the separate Drive / Chat entries only.

### 1.2 Setup (pre-auth) — one click, choose on Google's screen

The setup screen **explains** the products but has **no toggles**. To minimise decision fatigue,
the user makes a **single** choice — on Google's own consent screen — about what to allow. Plot
requests the union of all product scopes; Google's granular consent lets the user deselect any.

```
┌──────────────────────────────────────────────────┐
│  Connect Google              kris@plot.day  ▾      │
│  Mail, Calendar, and Tasks                         │
│                                                    │
│  Plot can sync these from your Google account.     │
│  You choose what to allow on Google's next screen. │
│                                                    │
│   ✉️  Mail        Important email → threads,        │
│                   reply & triage from Plot         │
│   📅  Calendar    Events, agenda, and RSVPs         │
│   ✓  Tasks        Google Tasks ↔ Plot to-dos       │
│   👤  Contacts    Names & photos on the people      │
│                   you work with                    │
│                                                    │
│        ┌────────────────────────────────┐         │
│        │     Continue with Google  →     │         │
│        └────────────────────────────────┘         │
└──────────────────────────────────────────────────┘
```

- **No Plot-side toggles.** The initial consent requests **every** product scope, and **Google's
  consent screen is the single place the user chooses** what to grant (Google's granular consent
  lets them uncheck individual scopes).
- After auth we reconcile against the scopes actually granted (§1.3) and auto-enable the granted
  products with smart default channels (§1.5).
- **Dependency / risk:** this leans on Google reliably surfacing per-scope checkboxes, and the
  "forgot to tick the box" mistake becomes more likely with no Plot-side pre-filter. That mistake
  is recovered by the post-auth trailing toggles + batch re-auth (§1.4) — the user flips the
  product on and re-consents. Confirm Google's granular-consent behaviour during planning.

### 1.3 Post-auth status — what actually got enabled

After consent we reconcile against the **scopes actually granted**. Channels are already auto-
enabled with smart defaults (§1.5). Each product row carries a **trailing toggle**; `›` opens that
product's channels.

```
┌──────────────────────────────────────────────────┐
│  🇬  Google · kris@plot.day            [Reconnect] │
│                                                    │
│  ENABLED                                           │
│   ✉️  Mail         Inbox + 2 labels       ›    ◉   │
│   📅  Calendar     2 of your calendars    ›    ◉   │
│   👤  Contacts     On                          ◉   │
│                                                    │
│  NOT ENABLED                                       │
│   ✓  Tasks         You skipped this            ○   │
│                                                    │
│  ( ◉ = trailing toggle on    ○ = off )             │
│                                                    │
│  [ Manage on Google ]            [ Disconnect ]    │
└──────────────────────────────────────────────────┘
```

- Toggling an enabled product **off** is a **local** action (no re-auth) — see §2.5.
- Toggling a not-enabled product **on** stages a re-auth (§1.4).
- A **Save** button appears only when there are pending non-scope edits (a local disable, a
  channel tweak); a clean screen shows no Save.

### 1.4 Batch re-auth (the "forgot a box" fix)

Toggling a not-yet-granted product on is **staged**, never an instant per-product OAuth. Staging
anything that needs a new scope swaps **Save** for one **Continue with Google**, so a single
consent grants everything staged at once.

```
After toggling Tasks ON under NOT ENABLED:
┌──────────────────────────────────────────────────┐
│  WILL BE ENABLED  (needs Google permission)        │
│   ✓  Tasks                                     ◉   │
│                                                    │
│  ⚠ Please reconnect to enable Tasks                │
│            ╔═══════════════════════════╗           │
│            ║  Continue with Google  →  ║           │
│            ╚═══════════════════════════╝           │
└──────────────────────────────────────────────────┘
```

- Toggle on **any** number of not-enabled products → they collect under **"Will be enabled"**,
  plain Save is suppressed, and one **Continue with Google** re-runs consent (Google shows the
  full set with already-granted scopes pre-ticked, so the user just ticks what's missing).
- On return, we reconcile `token.scopes`; products whose scope is now present flip to ENABLED.
  Idempotent — if the user forgets the box again, the product is simply still under NOT ENABLED.
- Pure non-scope edits (local disable, channel tweaks) keep the normal **Save** with no reconnect.

### 1.5 Per-product refine (channels) — only when wanted

Tapping a product (`›`) opens its resource list, each row a **trailing toggle**. **Owned resources
default on; shared/foreign default off** — never auto-import another person's calendar or "Shared
with me" content.

```
┌──────────────────────────────────────────────────┐
│  ‹ Calendar                                        │
│  YOUR CALENDARS                                    │
│   kris@plot.day (primary)                      ◉   │
│   Personal                                     ◉   │
│  SHARED WITH YOU                                   │
│   Team Holidays                                ○   │
│   Alex Rivera                                  ○   │
│   New calendars you create: sync automatically ◉   │
└──────────────────────────────────────────────────┘
```

- Mail: Inbox + a few high-signal labels on; the rest off.
- Tasks: all your task lists on.
- Calendar: your own calendars on; shared/subscribed off.

### 1.6 Agenda gating becomes permission-aware

Today "show the agenda" = "a connected source declares a schedule link type" — a *static* per-
connector property (`twist_instance.dart:240-269`, `hasCalendarConnectionInCache`). With one
connection covering Mail+Calendar+Tasks, that signal is wrong: the connection exists even when
the user skipped Calendar.

New rule:

> **has-calendar** = the connection has the **Calendar product enabled** =
> Calendar's scope is granted **AND** ≥1 calendar channel is enabled.

Implementation keeps the client predicate unchanged by making the composite's **effective
`linkTypes`** a function of *enabled* products (§2.5): when Calendar is enabled, the connection's
serialized `linkTypes` include the schedule-bearing `event` type; when it isn't, they don't. So
`linkTypesIncludeSchedules` keeps working, and the agenda appears/disappears as Calendar is
enabled/revoked, with no change to the gating call sites.

---

## Part 2 — Architecture

### 2.1 The runtime already isolates per-module (the key enabler)

The twist runtime builds each connection as a **tool tree** and isolates three things by
`(twist_instance_id, tool-path)`:

- **State** — `Store` is keyed `"<twistInstanceId>:<toolPath>"` (`workers/api/src/state/storage.ts`).
- **Scheduled callbacks** — `callbacks` rows carry a `path` column, e.g. `["Mail"]`, `["Calendar"]`
  (`workers/api/src/state/callbacks.ts`).
- **Webhooks** — an inbound hook resolves its callback token → `{ twist_instance_id, path,
  functionName }` and dispatches to that exact path (`workers/api/src/twist/invoke-webhook.ts`).

**Therefore, if each product is a child tool of one composite connector, per-product isolation of
state / scheduled sync / webhooks is automatic** — no collisions, no new plumbing. This is what
makes a single connection internally maintainable.

Billing already counts **per `twist_instance` with ≥1 enabled channel**
(`workers/api/src/utils/limits.ts:getPersonalConnectionCount`), so **one composite = one charge**,
automatically.

### 2.2 `ProductModule` (new, in `public/twister/src/`)

Encapsulates one product and nothing about accounts/billing/OAuth shell:

- `key` (stable: `"mail"`, `"calendar"`, `"tasks"`, `"contacts"`), `label`, `description`, `icon`
- `scopeGroup`: `{ id, label, description, scopes: { required, optional? }, default }`
- `channelNoun`, `linkTypes`, `channelless?: boolean` (Contacts has no channels)
- `getChannels(token)` — returns channels with the **owned-vs-shared default** baked in
- `onChannelEnabled` / `onChannelDisabled`
- write-back hooks: `onNoteCreated`, `onNoteUpdated`, `onLinkUpdated`, `onScheduleContactUpdated`,
  `onThreadRead`
- webhook + scheduled-sync handlers

A `ProductModule` is essentially "a connector minus the account/instance/charge concerns."

### 2.3 `CompositeConnector extends Connector` (new, in `public/twister/src/`)

The provider-agnostic shell that composes modules as **child tools** and:

- **Scopes** — aggregates each module's `scopeGroup` into the connection's `scopes` as **one
  optional scope group per product** (reuses today's `ScopeConfig` / `enabledScopeGroups`). The
  **initial consent requests the union of all groups** (Google's granular consent is the chooser);
  `enabledScopeGroups` is reused for incremental re-auth from the status modal.
- **Channels** — **namespaces channel ids by module key**. A module returns `Label_42`; the
  composite exposes `mail:Label_42` and routes `onChannelEnabled("mail:Label_42")` back to the
  Mail module after stripping the prefix. `channel_id` stays opaque text → **no schema change**.
  (A dedicated `product` column on `channel` is the heavier alternative; we choose the prefix.)
- **Routing** — dispatches webhooks/write-backs/lifecycle to the owning module (webhooks by
  callback `path`; write-backs by the link's type / channel's product namespace).
- **Effective link types** — computes the connection's `linkTypes` as the **union over *enabled*
  modules** (drives §1.6).
- **getChannels** — calls each *granted* module's `getChannels`; modules whose required scope is
  absent contribute nothing and read as "not enabled."

### 2.4 Provider composites

```ts
class GoogleConnector    extends CompositeConnector { provider = Google;    modules = [Mail, Calendar, Tasks, Contacts]; }
class MicrosoftConnector extends CompositeConnector { provider = Microsoft; modules = [Mail, Calendar, ToDo, Contacts]; } // later
```

Existing **Gmail / Calendar / Tasks** connector sync code is **re-homed into modules** — logic
preserved, just moved under the composite. Contacts already exists as a supporting connector and
becomes the Contacts module.

### 2.5 One enablement rule drives everything

```
enabled(module) = module.scopeGroup.required ⊆ token.scopes
                  AND NOT locally turned off
                  AND (module.channelless OR ≥1 enabled channel)
```

Turning a product **off** in the status modal is a **local** action (no re-auth): channel products
turn all their channels off; the channelless Contacts uses a per-product "off" flag stored in the
module's namespaced state. Turning a product **on** re-enables locally if its scope is already
granted, or stages a re-auth (§1.4) if not.

This single predicate feeds:

1. the **status modal** (ENABLED vs NOT ENABLED, §1.3),
2. the connection's **effective `linkTypes`** (§2.3) — written back to `twist_instance` whenever
   enablement changes, so the client's existing has-calendar logic stays correct (§1.6),
3. which modules' `getChannels` / sync / write-back actually run.

### 2.6 API surface

- **Provider/source metadata gains a generic `products` array** (not Google-specific): each item
  = `{ key, label, description, icon, scopeGroupId }`. The Flutter setup and status screens render
  from this array, so Microsoft reuses it unchanged.
- **Integrations endpoint returns derived per-product status**: `{ key, enabled, reason }`
  (`reason` ∈ `granted | scope-missing | locally-off | no-channels`). The client never sees raw
  scopes; it sees derived enablement. Granted scopes continue to live in KV in the token
  (`StoredTokenData.scopes`).
- **Batch re-auth**: staged product keys → composite maps to the union of their scope group ids →
  existing `getAuthUrl({ enabledScopeGroups })` incremental OAuth → on return, reconcile.

### 2.7 What does **not** change

- Billing/limits (`getPersonalConnectionCount`) — one composite instance counts as one.
- The webhook ingestion path, callback DO, and `Store` keying — all already path-aware.
- Cross-user thread convergence via globally-unique `source` keys.

---

## Part 3 — Migration (bankruptcy)

On deploy:

1. **Archive** every existing user-owned `twist_instance` for the old Gmail / Calendar / Tasks
   connectors: `archived_at = now()`. **Never delete** (synced-table rule). Their channels and
   already-synced threads/links remain as historical content.
2. **Replace catalog entries**: the three old product twists are hidden from the picker (the one
   composite entry takes their place). Archived instances may still reference the old twist rows —
   that's fine; they no longer run.
3. **Prompt affected users** to add the new connection, reusing an existing surface (e.g. the
   connection-status tile / a one-time notice): "We've combined your Google connections —
   reconnect to keep syncing." One re-auth via the new setup flow.
4. Old connector packages stay in the tree (inert) until a later cleanup; new syncs run through
   the composite.

**Continuity note / risk:** once a user re-adds the composite, it re-syncs from Google using the
same globally-unique `source` keys, so upsert-by-source should converge onto existing threads
rather than duplicating them. The plan must **verify** this convergence (source keys are
instance-independent) and, if any window of duplication exists for very recent items, accept it as
the known cost of bankruptcy. This is the main thing to test before shipping the migration.

---

## Risks & open implementation details (for the plan, not blockers)

- **Google granular consent.** The whole pre-auth simplification (§1.2) depends on Google actually
  surfacing per-scope checkboxes for this scope set so the user can choose there. Confirm during
  planning; if Google's granular consent proves unreliable for some sensitive scope, we fall back
  to a lightweight Plot-side pre-selection (trailing toggles) for just that scope.
- **Channel-id prefixing vs. a `product` column.** We chose prefixing (`mail:`, `calendar:`,
  `tasks:`) to avoid a schema/sync change. The plan must confirm no existing channel id format
  already contains the delimiter, and that the Flutter per-product grouping can derive the product
  from the prefix (or carry a lightweight `product` field on the synced channel payload).
- **Effective-linkTypes writes.** Recomputing and persisting the connection's `linkTypes` on every
  product enable/disable is a write to `twist_instance` (bumps `seq`, syncs to clients). Confirm
  this is cheap and that the has-calendar derivation is exact (scope granted AND ≥1 calendar
  channel enabled).
- **Write-back & webhook teardown on disable.** Disabling a product must stop its watches and
  suppress its write-backs; routing must check module-enabled before dispatching.
- **Tasks/Chat connector existence.** Tasks is in the bundle and assumed to exist as a connector to
  re-home; Chat is out of scope (stays separate). Confirm during planning.
- **Google OAuth review.** Bundling Mail (gmail.modify) + Calendar + Tasks + Contacts in one
  consent is still a sensitive-scope set; confirm the verified-app config covers the union.

## Testing strategy

- **Pure unit tests** for the enablement predicate (including local-off and channelless cases),
  channel-id namespacing/routing, effective-linkTypes computation, and the owned-vs-shared default
  selection per module.
- **Composite routing tests**: a webhook/callback/write-back addressed to `["Calendar"]` reaches
  the Calendar module and not Mail; disabled modules don't dispatch.
- **Reconcile tests**: granted-scope subsets produce the correct ENABLED/NOT-ENABLED status and
  the correct effective link types (and thus correct has-calendar).
- **Migration test**: archiving old instances doesn't delete synced data; re-adding the composite
  converges threads by `source` rather than duplicating.
- **Flutter**: setup renders product explanations from the generic `products` array with no
  pre-auth toggles; batch-staging via trailing toggles suppresses Save and shows "Continue with
  Google"; status screen reflects derived enablement; agenda appears only when Calendar is enabled.
  Reuse `SelectModal` keyboard nav and trailing-toggle styling.

## Provider-agnostic check (Microsoft readiness)

Nothing in `ProductModule`, `CompositeConnector`, the `products` metadata array, the
`enabledScopeGroups` flow, the status UI, or the agenda derivation is Google-specific. Microsoft
ships as `MicrosoftConnector extends CompositeConnector` with its own modules and provider — no
new permission/product UX or plumbing.
