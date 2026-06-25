# Phase 2/3 — Calendar (then Mail/Tasks/Contacts) sync re-homing: architecture

_Design captured 2026-06-23 from reading `public/connectors/google-calendar/src/google-calendar.ts`. This
is the detail behind plan Task 8. It needs a running local API worker + `tsc`/tests to implement safely
(verify-as-you-go on a shipped connector); do NOT write it blind._

## The governing constraint: callbacks dispatch by method name on the connector instance

`google-calendar` schedules its own continuations with `this.callback(this.initCalendar, calendarId)` /
`this.callback(this.syncBatch, …)` / `this.callback(this.renewCalendarWatch, …)`. A callback token is a
**reference to a method on the deployed connector instance** — when the runtime runs the token it calls
`connector.<thatMethod>(...args)`. Consequences for the combined `Google` connector:

- The combined connector **must expose its own callback methods** that the calendar flow targets. You
  cannot point a callback at a function living only in a product module — it has to be a method on the
  class the runtime instantiates (`Google`).
- Therefore the calendar sync logic gets **extracted into standalone functions** (taking a host context),
  and `Google` gets **thin callback methods** that forward to them (product-keyed), e.g.
  `Google.calendarInit(calendarId)`, `Google.calendarSyncBatch(calendarId, batchNumber, phase, initialSync?)`,
  `Google.calendarRenewWatch(calendarId)`. `GoogleCalendar` keeps its existing method names (delegating to
  the same extracted functions) so its deployed callbacks keep resolving — **callback backward-compat**.
- **Callback signature backward-compat** still applies to BOTH connectors: only append optional args.

## The reuse shape: extract sync into functions over a host context

Define an interface capturing exactly what the calendar sync touches on `this`:

```ts
export interface CalendarSyncHost {
  // state (the combined connector implements these with a "calendar:" prefix)
  set(key: string, value: unknown): Promise<void>;
  get<T>(key: string): Promise<T | null>;
  clear(key: string): Promise<void>;
  // task/callback machinery — callback() must target a METHOD on the host connector
  callback(method: (...a: any[]) => any, ...args: any[]): Promise<Callback>;
  runTask(cb: Callback): Promise<void>;
  scheduleRecurring(key: string, cb: Callback, opts: {...}): Promise<void>;
  cancelScheduledTask(key: string): Promise<void>;
  // tools
  tools: { integrations: Integrations; network: Network; googleContacts: GoogleContacts; store: Store };
}
```

Extract `initCalendar`, `syncBatch`, `setupCalendarWatch`, `scheduleWatchRenewal`/`renewCalendarWatch`,
`stopCalendarWatch`, `onWebhook`-body, `onScheduleContactUpdated`-body, `clearBuffers`, `resolveCalendarId`,
`ensureUserIdentity`, `getUserEmail`, plus the event-transform helpers, into `google-calendar/src/sync.ts`
as functions `(host: CalendarSyncHost, …args)`. `GoogleCalendar`'s methods become one-line delegations
passing `this`; **its 4 tests + behavior stay identical** (the guardrail).

Catch: the callbacks created INSIDE the extracted functions (`host.callback(host.<method>, …)`) must target
the **host's** method. Two options: (a) pass the method references in as part of the host (a small
`callbacks: { syncBatch, renewWatch, … }` map the host supplies), or (b) keep the callback-creation in the
connector's thin methods and have extracted functions return "what to schedule next" descriptors the
connector turns into callbacks. **(b) is cleaner** — extracted functions stay pure-ish and the connector
owns all `callback()` calls (so method identity is unambiguous). Decide when implementing.

## State-key namespacing in the combined connector

`google-calendar` uses bare keys: `sync_state_<id>`, `last_sync_token_<id>`, `calendar_watch_<id>`,
`user_email`, lock `sync_<id>`, buffers `pending_*`/`seen_master_*`. In `Google`, the calendar product's
host must **prefix every key with `calendar:`** so mail/tasks/contacts state can't collide. Cleanest: the
combined connector's `CalendarSyncHost` impl wraps `set/get/clear/store.list/acquireLock` to prepend
`calendar:`. The standalone connector's host uses no prefix (unchanged keys → no migration).

## `Google.build()` must declare the union of tools

Currently `Google.build()` returns only what the structural core needs. For calendar it must add:
`network: build(Network, { urls: ["https://www.googleapis.com/calendar/*", <gmail>, <tasks>, <people>], webhooks })`,
`googleContacts: build(GoogleContacts)`, and for later products `files` (gmail attachments) + `tasks` tool.
Build the URL allowlist as the union across products. `integrations` + built-in `store`/`callbacks`/`tasks`
are already present.

## Webhook + RSVP demux (already designed in the structural core)

- `Google.onWebhook(req, token)`: the webhook token must carry the product key (calendar webhooks are
  registered with a `calendar:`-tagged token) → dispatch to the calendar webhook handler with the bare
  calendar id. `createWebhook` is called by the calendar setup with a product-tagged resource id.
- `onScheduleContactUpdated(thread, …)`: resolve product via `thread.meta.channelId` (namespaced
  `calendar:<id>`) using `resolveProductForChannelId`; fall back to `resolveProductForLinkType("event")`.

## Verification plan (needs the local API worker)

1. Unit: extracted functions over a fake host (state map, recording callback/runTask) — assert the sync
   state machine (quick→full phases, sync-token persistence, watch scheduling) behaves as before. Mirror
   any existing google-calendar tests against the extracted functions.
2. `GoogleCalendar` 4 tests stay green; `Google` package tsc + tests green.
3. Runtime load: with the local worker running, confirm the runtime can instantiate `Google` (build() tools
   resolve, callback methods register) — previously impossible to check.
4. End-to-end (needs the connector registered in the local catalog + a Google OAuth connection — Phase 4
   catalog work + a real account): enable a `calendar:<id>` channel → initial backfill produces event
   threads → an event change via webhook/poll updates them → an RSVP write-back reaches Google. This is the
   real fidelity check and is why this work wants a live, supervised session.

## Order
Calendar first (this doc), verify e2e, THEN Mail (Pub/Sub), Tasks (polling), Contacts (enrichment) as
Phase 3 — same host-extraction pattern, one product at a time, each keeping its connector's tests green.
