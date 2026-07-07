# App-Open Sync Catch-Up Latency — Design

**Date:** 2026-07-06
**Goal:** When the app is opened/resumed after being closed for a while, all
updated threads should be visible as quickly as possible — target **~1-2s to
updated thread rows** in the feed (overnight absence, normal network), with
note bodies trailing by at most another round trip or two.

**Scope decision:** client-first. All changes are Flutter-client-side against
existing `/sync/*` endpoints and parameters. No server or protocol changes.
Escalate to a combined server catch-up endpoint only if post-deploy
measurements say the target is still missed.

## Background — where the time goes today

On resume the app immediately runs a client-driven seq-cursor sweep
(`Store._syncAll()` → `SyncOrchestrator.syncAll()`). The WebSocket
intentionally does not replay missed changes (the server clears the pending
watermark on connect — `sync_user_on_connect`, `workers/api/src/state/user-sync.ts`),
so every reopen pays the full multi-entity poll. The cost structure:

1. **Serialized dependency levels** (`sync_orchestrator.dart` `_computePullLevels`):
   actor → role → priority → thread → note. Threads pull at level 3, notes at
   level 4, each level an awaited barrier even when upstream entities return
   0 rows.
2. **`Thread.pullInitial()` runs on every sync** (entity pullFn is
   `pullInitial(); pull()`): cursor checks, a **duplicate incremental links
   pull** (`thread.dart:945`, repeated at `:970`), then `pullAgenda(null)` and
   `pullActivityFeed(null)` — **real HTTP round trips every time**. This is a
   **bug**, not a design: the agenda/feed calls were added in `1c5b33444`
   (2026-03-16) as initial-sync seeding ("so views have data immediately"),
   but unlike the `initial: true` pulls around them they have no run-once
   guard — `Store.pullTo` with a null target has no caught-up short-circuit
   (`store.dart:2153-2166`), only the `noMore` "server fully exhausted" flag.
   Consequences: the agenda call crawls forward until future items exhaust
   (then goes quiet via `noMore`); the feed call advances a **backward crawl
   through the user's entire thread history** — one 200-row page plus 3 slice
   pulls (links/schedules/threadTags) per invocation — on every `syncAll`
   AND every broadcast-driven thread `syncSubset` (debounced 0.3-2s), slowly
   downloading the whole account against the intentional partial-sync design,
   and adding 2-8 serial round trips ahead of the incremental thread pull.
   The intended model: initial pull once; feed/agenda pages on demand when
   scrolling; resume pulls new/updated only — never additional pages.
3. **Serial sub-entity pulls**: `Thread.pull()` runs 6 sequential `Store.pull`
   calls (links → threads → schedules → threadTags → threadReactions →
   threadAssociations, `thread.dart:968-979`); `Note.pullUpdates()` runs 3
   (`note.dart:481-485`).
4. **A fresh TCP+TLS handshake per request**: `lib/api/api.dart` uses
   package:http top-level functions (`http.get`/`http.post`/…), which create
   and close a new client per call. Every round trip pays ~50-150ms+
   connection setup (worse on mobile radio).
5. **Page-loop drain** at 200 rows/page (`BaseTable.limit`, `store.dart:237`);
   the server accepts up to 1000 (`workers/api/src/app/sync/helpers.ts:6-7`).
6. **Double catch-up on resume**: the Store lifecycle observer
   (`store.dart:4668-4691`) fires `_startSync`/`_syncAll`, and the broadcast
   client's resume reconnect (`broadcast.dart:127-135`) fires
   `_handleReconnected` → another `_syncAll` (`store.dart:2420-2426`). The
   orchestrator's per-entity completer dedupe turns the overlap into a
   `_pullDirty` re-pull of every entity — a full second ~19-request sweep.

Net: updated thread rows land after ~7-9 serialized cold-connection round
trips (≈1.5-4s+ before any real data volume); notes after ~10.

Server-side incremental `/sync/threads` is already fast post-#325
(candidate-id pre-filter; 0.5-22ms typical) and is not addressed here.

## Design

### 1. Restructure the thread & note entity pulls

- **`Thread.pullInitial()` is skipped entirely when initialized**: one
  `syncStates` existence check (the `threads` cursor) gates the whole method.
  Uninitialized stores keep the current behavior (bounded initial pulls +
  agenda/feed seed).
- **`Thread.pull()` parallelizes all 6 seq pulls** via `Future.wait`:
  threads, links, schedules, threadTags, threadReactions, threadAssociations.
  The old links-before-threads ordering only protected feed sort order;
  `activity_at` is computed at query time from local joins (thread.dart
  `_watchActivityFeedIds` SQL), so a thread landing ~100-300ms before its link
  causes a brief sort settle that watch streams self-heal — already the case
  across page boundaries today.
- **`Note.pullUpdates()` parallelizes its 3 pulls** (notes, noteTags,
  noteReactions). The notes-before-tags constraint is push-only (server
  rejects tags for unpersisted notes); on pull, an orphan tag row simply
  doesn't render until its note lands.
- **The recurring agenda/feed backfill is removed entirely** (bug fix — see
  Background #2). Skipping `pullInitial` when initialized removes it from
  every recurring sync (`syncAll` and broadcast-driven `syncSubset`) along
  with the duplicate links pull; a genuinely-initial run keeps the agenda +
  feed seed exactly as today. `fullResync`'s own explicit seed calls
  (`store.dart:2997-2998`) and `_threadCritical` (fresh-device critical sync)
  are unaffected. After this change, feed/agenda pages are fetched ONLY on
  initial sync, full resync, and on-demand scrolling.
- **The Everything view gets the on-demand pull it was silently missing.**
  Everything-mode deep scroll is currently pure local SQL (`fetchAllTabPage`)
  and its feed-sync trigger is skipped (`_pendingFeedSync = state.context`,
  null in Everything mode — `priority.dart:3925, 3940-3941`); it only worked
  because the buggy background crawl kept deepening local history. Fix:
  mirror the per-focus demand path for the global scope — (a) entering
  Everything queues the same deferred feed sync against the global cursor
  (`Thread.pullActivityFeed(null)`, sync state `activity-feed`), and (b) the
  Everything fetch-more path (`_fetchMoreAllTab`) pulls another global page
  before declaring the append cursor exhausted, with the same
  fetch-more-loop/noMore semantics as `_triggerActivityFeedSync`
  (`priority.dart:4629-4695`). Agenda needs no equivalent: its forward crawl
  is finite (goes quiet via `noMore`), new events arrive via seq deltas, and
  per-focus agenda fetch-more already exists.

### 2. Incremental wave ordering in the orchestrator

`syncAll`'s pull phase stops using dependency-topo levels and uses an explicit
two-wave plan (a static list, analogous to `_criticalEntities`):

- **Wave 1:** `thread`, `note` — what the user is waiting for. With the
  parallelized pullFns this is ~9 concurrent requests; updated thread rows
  land in round trip #1.
- **Wave 2:** `actor`, `priority`, `role`, `group`, `topic`, `teamUser`,
  `userSettings`, `priorityBlock`, `twistInstance`, `session`, `channel`,
  `twistConnection` — typically all 0-row on reopen.
- **Then:** `Note.ensureUnreadActiveThreadsLoaded()`; then the push phase,
  unchanged. (No agenda/feed step — see §1: the recurring backfill is
  removed, not relocated.)

Why incremental waves are safe (see §4 for the audit): rows are idempotent
`insertOrReplace` upserts, cross-entity joins happen at query time, and the
UI tolerates missing referents transiently, re-emitting via Drift watch
streams when they land.

Unchanged surfaces:

- `syncInitialCritical` / `syncInitialDeferred` keep their current
  topo-ordered behavior (fresh-device correctness and the 30s budget are
  their own tuned path).
- `syncSubset` (broadcast path) keeps its dependency-closure shape; it
  inherits the parallelized pullFns and the removal of per-broadcast
  agenda/feed pulls.
- Per-entity completer dedupe (`_pullCompleters` / `_pullDirty`) unchanged.
- Each entity's `pullFn` still calls its own `pullInitial` first, so an
  uninitialized entity (e.g. a table added by an app upgrade) self-seeds
  regardless of wave order.

Burst sizing: wave 1 ≈ 9 concurrent requests, wave 2 ≈ 12 — versus today's
max level width of ~4-6, with the same ~19 total requests. Cloudflare serves
HTTP/2+ (multiplexed on web); native platforms open parallel connections.
Server queries are all short post-#325. The existing 429 cooldown
(`sync_orchestrator.dart:751-781`) remains the backstop. No client-side
semaphore unless measurements show a need.

### 3. Transport: shared HTTP client

Replace the per-call top-level `http.get`/`http.post`/… in `lib/api/api.dart`
with a single shared long-lived `http.Client`, so connections are kept alive
and reused across requests. Web is unaffected (browser fetch pools
automatically). Resilience: a request failing with `ClientException` (e.g.
stale keep-alive socket after mobile backgrounding) swaps in a fresh shared
client; **idempotent requests (GET) retry once** on the fresh client before
surfacing the existing `NetworkException` mapping, while mutating requests
(POST/PUT/PATCH/DELETE) surface the error immediately as today — a blind
retry could double-apply a non-idempotent write (e.g. double-send a note).
**The dead client's `close()` is deferred past the longest request timeout**
(amended during implementation review): `IOClient.close()` force-terminates
every connection it still holds, so closing immediately would abort
unrelated concurrent in-flight requests (e.g. a healthy note-send POST) as
collateral — a regression versus per-call clients that the parallelized
sync pulls would make routine. An identical-reference guard ensures
concurrent failures produce one recreation, not a cascade.
`_retryOn401` / `_retryOn429` wrappers unchanged.
This benefits every API call in the app, not just sync.

### 4. Entity-dependency safety

Relative landing order changes for: thread before priority/role/actor; note
concurrent with thread (a note can precede its thread); thread-aux
(tags/reactions/schedules/links) concurrent with threads; channel /
twistConnection concurrent with twistInstance. Three safety layers:

1. **Write layer — safe**: the local Drift/SQLite DB does not enable
   `PRAGMA foreign_keys` (verified: no occurrence in `lib/`; SQLite default
   OFF; the two `.references()` declarations in `priority_block.dart` /
   `session.dart` are declarative only). All pull writes are
   `insertOrReplace`. Orphan child rows persist harmlessly and surface when
   the parent lands. Implementation adds a test asserting `PRAGMA
   foreign_keys` is off so this assumption can't silently rot.
2. **SQL read layer — safe by construction**: feed/agenda/thread queries join
   and aggregate such that missing referents filter out or null out (e.g.
   `activity_at` MAX-over-joins).
3. **Dart resolution layer — audited and hardened**: sweep `lib/state/`,
   `lib/page/`, `lib/widget/`, and `processPulledRows` overrides for
   presence-assuming lookups across exactly the reference pairs above
   (`firstWhere` without `orElse`, null-assert `!` after cross-entity
   lookups, `map[key]!`). Convert findings to skip-and-self-heal
   (`firstWhereOrNull` + render without the decoration), matching the
   documented unresolved-contact pattern (`sync_orchestrator.dart:281-292`
   region).

**Orphan-tolerance regression tests**: insert child rows with absent parents
(note without thread, thread without priority, threadTag without thread,
channel without twist instance), pump the feed/agenda/thread pages, assert no
exception; then insert the parent and assert the UI settles correctly.

### 5. Catch-up page size

Raise the seq-cursor `limit` from 200 → 500 for high-churn entities:
`ThreadsBase` (incremental), `NotesBase`, `LinksBase`, `ThreadTagsBase`,
`NoteTagsBase`, `SchedulesBase`. Server `MAX_LIMIT` is 1000, so old and new
servers both accept it. No effect when fewer than 200 rows changed; ~2.5×
fewer page-loop round trips after long absences.

### 6. Resume sync coalescing

Coalesce concurrent `_syncAll` invocations on a shared in-flight future in
`Store`: a second catch-up trigger (e.g. broadcast reconnect during a
resume-triggered sync) awaits the in-flight sweep instead of queueing a
`_pullDirty` re-pull of every entity. Each entity pull always fetches up to
the server's current horizon at request time, so the in-flight sweep covers
the second trigger's window; the `_pullDirty` mechanism remains for
broadcast-driven changes that arrive mid-pull.

### 7. Telemetry & verification

- **New `sync_catchup` analytics event** (existing `Tracker`), fired once per
  `syncAll`: `trigger` (startup / resume / reconnect / connectivity),
  `total_ms`, `wave1_ms`, `threads_ms`, `notes_ms`, `rows_total`,
  `requests`, `pages`. Provides prod p50/p95 before→after and a permanent
  regression dashboard. (Requires plumbing a trigger label from the call
  sites: `_setupConnectivityListener`, lifecycle observer, `_handleReconnected`,
  `_startSync`.)
- **Local before/after**: run with `SYNC_PERF_LOG=true`
  (`lib/store/logging.dart:8`), background the app, mutate data via a second
  session, resume, compare per-pull timings.
- **Tests**: orchestrator wave-order unit tests (mirroring the
  `criticalPullLevels` pattern), parallelized pullFn tests,
  `pullInitial`-skip-when-initialized test (asserting no agenda/feed/links
  requests on a recurring sync — the backfill-bug regression guard),
  Everything on-demand fetch-more tests (global page pulled when local data
  exhausts; noMore stops the loop), `_syncAll` coalescing test,
  orphan-tolerance widget tests (§4), FK-pragma-off test, plus the full
  existing suite.

## Expected outcome

Critical path to updated thread rows: ~7-9 serialized cold-connection round
trips (≈1.5-4s+) → 1 warm parallel round trip (≈200-500ms). Notes land in the
same wave. Comfortably inside the ~1-2s target, with the page-size bump
covering long-absence drains and telemetry to prove it in prod.

## Risks & mitigations

- **Transient UI inconsistency from reordered landings** — bounded to
  sub-second windows, self-healing via watch streams; hardened by the §4
  audit + tests.
- **Burst load on the API** — same total request count, higher concurrency;
  short server queries post-#325; 429 cooldown as backstop; can add a
  client-side cap later if telemetry shows contention.
- **Shared HTTP client stale sockets on mobile resume** — recreate-and-retry-
  once on `ClientException`.
- **Everything deep-scroll history is now demand-fetched, not pre-warmed** —
  the background crawl no longer downloads history ahead of scrolling, so
  Everything's scroll shows a trailing fetch (same spinner semantics as
  per-focus feeds) instead of instant local pages. Existing accounts keep
  whatever history the crawl already downloaded. If the on-demand pull feels
  slow in practice, a bounded prefetch can be layered on later — but the
  default is the intended partial-sync model.

## Out of scope (explicitly)

- Combined server-side catch-up endpoint / "changed tables" manifest
  (escalation path if measurements miss the target; the
  `/sync/thread-detail` + `prefetched` envelope pattern in
  `Note.pullForActivity` is the template).
- Server-side `/sync/threads` query work (already optimized in #325).
- WebSocket replay of missed changes on reconnect.
- `ensureUnreadActiveThreadsLoaded` tuning (cap 50 / concurrency 5 unchanged).
