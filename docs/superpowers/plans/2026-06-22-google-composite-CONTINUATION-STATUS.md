# Google Composite Connection — Resume Guide

_Self-contained status for resuming this work (a fresh session or dispatched agent should be able to
continue from this doc alone). Last updated 2026-06-23._

**What this is:** replacing the 3 separate Google connectors (Gmail / Calendar / Tasks, each its own
twist_instance + OAuth + charge) with ONE connection — **"Google Mail, Calendar, and Tasks"** (Mail +
Calendar + Tasks + Contacts; Drive & Chat stay separate). Authoritative design:
`docs/superpowers/specs/2026-06-22-google-composite-connection-design.md`. Plans:
`…-phase-2-google-connector.md`, `…-2026-06-23-google-composite-sync-rehoming-design.md`.

## ✅ FIXED — the connect bug (PR plotday/core #430, off `main`)
_Was: after connecting (all scopes granted), all products showed OFF and enabling one triggered a re-auth._

**Root cause (both symptoms, one place):** `_buildCompositeView` in `apps/plot/lib/widget/setup_source.dart`
drove the toggle/display from the **server's `productStatus.enabled`**, which is correctly `no-channels` on a
fresh connect — the EditSource opens on an **unsaved draft** (`isNewlyActivated`/setupMode), so nothing is
enabled server-side yet — even though scope IS granted and the owned `enabledByDefault` channels are already
**seeded locally** by `_applySuggestedDefaults` (→ `_localSelectedChannels`). So products read OFF, and the
not-enabled toggle staged a re-auth regardless of `reason`.

**Fix (Flutter-only — no server change needed):** drive each product row from `scopeGranted`
(`status.reason != scopeMissing`) + local channel selection instead of server `enabled`:
- `toggleOn = scopeGranted ? (channels.isEmpty ? true : anyChannelOn) : isStaged` → products read ON from the
  seeded owned channels;
- `canDrill`/keyboard-activator use `scopeGranted && length>1`;
- `toggleProduct`: `scopeGranted` → enable/disable channels **locally**; only `scopeMissing` → stage re-auth;
- `isSynced = isEnabled || (scopeGranted && anyChannelOn)` → preserves test (g) (server-synced product toggled
  off keeps its summary), while setup-mode seeded products show their count.
This mirrors the **standalone** model (seed defaults → enable on Save): `SaveSource` → `activateDraft` already
persists the seeded channels server-side, so no connect-time server auto-enable is required. The resume doc's
earlier "enable owned channels server-side on connect" framing was one option; the seed-and-Save path is the
clean fit for the existing draft/EditSource architecture.

Tests added in `setup_source_composite_test.dart`: **(i)** fresh-connect scope-granted/`no-channels` product
with seeded `enabledByDefault` channels reads ON; **(j)** toggling a scope-granted product enables its channel
locally and does NOT stage a re-auth. 10/10 composite tests green, `flutter analyze` clean.

⚠️ **Live verification still human-gated** (needs a connected Google account — OAuth browser): confirm all
granted products read ON after connect, toggling a granted product is local (no "Continue with Google"), and a
not-granted product still stages the re-auth.

## Workspace & branches
- Worktree: `/Users/kris.braun/code/plot/.claude/worktrees/google-composite-twister`.
- Parent branch **`google-composite-twister`** is a TANGLED SUPERSET (carousel, Hyperdrive infra,
  fix/launch-bugs, all the composite work). **Never merge it whole** — every shippable piece is
  cherry-picked into a clean branch off `main` (the way #416/#218/#417/#426 were).
- Public submodule (`public/`, repo `plotday/plot`) is on branch **`connector-google`** (pushed) — holds the
  combined connector + the twister SDK additions.

## PR / branch map
| Piece | State |
|---|---|
| Flutter composite UX base | ✅ MERGED — plotday/core **#416** |
| SDK `Connector.dynamicLinkTypes` flag | ✅ MERGED — plotday/plot **#218** (twister published 0.62.0) |
| Phase 1 core: `user.twist` dynamic link types view + deploy wiring | ✅ MERGED — plotday/core **#417** |
| Flutter composite UX polish (onboarding wrap, ProductSetupWidget, status spacing/labels, Contacts logo) | ✅ MERGED — plotday/core **#426** (2026-06-24) |
| **Connect bug fix** (products read ON after connect; toggle local, not re-auth) | ✅ MERGED — plotday/core **#430** (2026-06-24). Flutter-only; tests (i)/(j). |
| Combined **`Google` connector** + twister `Connector.products` (public) — ALL 4 products re-homed | ✅ **MERGED** — plotday/plot **#222** (public/main now `c5cffe8`). Calendar + Mail + Tasks + Contacts sync all in the one connector. |
| **Phase 4 endpoint** (workers/api): `/twist/:id/integrations` returns `products`+`productStatus`; pure `product-status.ts` | ✅ **OPEN / ready for review** — plotday/core **#431** (`core-google-products`, off `main`). Submodule re-pointed to public/main `c5cffe8` (commit `ecd09dc53`); MERGEABLE (BLOCKED = awaiting CI/review). Verified: twister builds, workers/api tsc clean, product-status 9 tests. |

## Local runtime (the verify loop — already set up this session)
- **API worker:** running via `pnpm --filter @plotday/api dev` (wrangler dev on **:8787**), log at
  `/tmp/plot-api-dev.log`. It hits the **worktree DB on :54335** (per `workers/api/.dev.vars`). Worker Loaders
  (`LOADER` binding) run connector isolates locally. If not running, restart it (background) and wait for
  `:8787` to answer.
- **Deploy the connector locally:** `cd public/connectors/google && pnpm exec plot deploy --api-url http://localhost:8787`
  (env defaults to `personal`; same `plotTwistId` row regardless of env). Stores the bundle for LOADER +
  writes `permissions._products` / `_dynamic_link_types`. Needs a valid `plot login` token (**user-gated**,
  done this session — re-run `pnpm exec plot login --api-url http://localhost:8787` if it expires).
- **Verify deploy landed:** `source ./.worktree-db && psql "postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres" -tAc "select permissions->'_products' from twist where name ilike '%Google Mail%' order by seq desc limit 1;"`
- **DB footgun:** ambient `$DATABASE_URL` may be stale (54322 = MAIN db). For any `pnpm apply-migrations`/`gen-migration`, override `DATABASE_URL` from `.worktree-db` (54335). `gen-migration`/`diff-schema-migrations` use Atlas's own docker dev DB, so they're safe regardless.

## What works end-to-end LOCALLY today
Connect "Google Mail, Calendar, and Tasks" → pre-auth `ProductSetupWidget` (product list, no scope toggles)
→ OAuth → post-auth composite status (product toggles, channels behind drill-downs) → enable a Calendar
channel → **events backfill as threads**. Gated entirely on `TwistIntegrations.isComposite` (= `products`
present), so non-composite connectors are untouched.

## Connector architecture (how reuse works — READ before touching sync)
`Google extends Connector<Google>` (one twist_instance/OAuth/charge), `dynamicLinkTypes = true`,
`scopes = {required:[], optional:[mail,calendar,tasks,contacts groups]}`, `products = PRODUCTS`.
- Channel ids are namespaced `"<productKey>:<rawId>"` (`product-channel.ts`: `namespace`/`parse`/`productKeyOf`).
- `getChannels` = `composeChannels(PRODUCTS_BY_KEY, token)` — scope-gates each product, prefixes ids,
  attaches per-product `linkTypes`.
- Per-product logic is reused from the shipped connectors by **mechanically extracting** their `this.*`
  methods into standalone functions over a host context. **Channel-listing** is fully extracted
  (`google-{calendar,gmail,tasks,contacts}/src/channels.ts`, each connector's `getChannels` delegates,
  their tests stay green). **Calendar initial backfill** is extracted to
  `public/connectors/google-calendar/src/sync.ts` (`runCalendarInit`/`runSyncBatch` return next-step
  descriptors; the CALLER owns `this.callback` scheduling — because callbacks dispatch by method name on the
  connector instance). `Google` mirrors `calendarInit`/`calendarSyncBatch` methods + a `calendar:`-prefixed
  `CalendarSyncHost`; `build()` declares `network`(calendar) + `googleContacts`.
- **Governing constraint:** a connector's continuations (`this.callback(this.method,…)`) dispatch to a method
  ON the connector instance — so re-homed sync needs mirrored callback methods on `Google`, not just
  functions. See the sync-rehoming design note.

## Remaining work (in order; orchestrate via background subagents, verify on the local worker)
1. **Calendar live updates + RSVP — ✅ DONE** (commit `f7f18bc` on `connector-google`, pushed; redeployed
   locally). Extracted watch/webhook/incremental + RSVP into `sync.ts`; `Google` has
   `calendarSetupWatch`/`calendarScheduleWatchRenewal`/`calendarRenewWatch`/`calendarOnWebhook`/
   `calendarStartIncrementalSync` + `onScheduleContactUpdated`; webhook routes via `createWebhook`'s callback
   ref (calendarId embedded in the URL, mirroring the standalone); RSVP routes by `thread.meta.syncableId`+
   `meta.id`. google-calendar 38 tests, google 59, both tsc clean, bundle green. **Calendar is now fully
   re-homed (backfill + live + RSVP).** ⚠️ Live-update *runtime* needs #406 in the worker + a cloudflared
   tunnel (human-gated) — local webhook setup self-skips on localhost.
2. **`tasks.ts`/`scheduleRecurring` — NO FIX NEEDED (stale-branch artifact).** `origin/main` already
   implements `scheduleRecurring`/`cancelScheduledTask` (merged via #406 `durable recurring tasks`), which
   the parent `google-composite-twister` forked before — that's the only `workers/api` tsc error on the
   parent, and it **vanishes when the Phase 4 endpoint is extracted onto a clean branch off main** (main has
   #406). Do NOT implement it on the parent. ⚠️ Consequence for LOCAL runtime only: the running worker (on
   the stale parent branch) lacks the #406 impl, so a connector calling `this.scheduleRecurring` (Calendar
   **watch renewal**) would fail at runtime locally — but live updates also need a cloudflared tunnel +
   connected account (already on the human-gated checklist), so this gap doesn't block structural work; it's
   covered once the connector runs from a main-based branch.
3. **Extract clean PRs — ✅ DONE** (cherry-picked clean off main, like #416/#426/#430):
   - public combined connector + twister `Connector.products` → **plotday/plot #222** (OPEN).
   - workers/api Phase 4 endpoint → **plotday/core #431** (DRAFT, blocked on #222 — see PR map).
   **Merge order:** #222 first → then re-point #431's `public` submodule from `eafc404` to public/main +
   regen `pnpm-lock.yaml` + un-draft #431. (Both branches pushed; scratch worktrees were removed.)
4. **Mail / Tasks / Contacts sync** (Phase 3) — same host-extraction pattern, one product at a time, keep
   each shipped connector's tests green. Then their `onEnable`/`onDisable` stop throwing `Phase 3`.
   - **Mail — ✅ DONE** (commit `f2b0027` on `connector-google-clean`, pushed → extends **#222**). Extracted
     gmail sync/send/watch → `gmail/src/sync.ts` over a `GmailSyncHost` (gmail.ts 2114→781); combined `Google`
     wires Mail via `makeMailHost()` (`mail:` namespaced) + `mail*` callback methods + write-backs
     (`onGmailWebhook`/`onNoteCreated`/`onThreadRead`/`onThreadToDo`/`onCreateLink`/`downloadAttachment`).
     `activate()` seeds `mail:auth_actor_id`; `build()` adds `files` + Gmail/People URLs. Verified: gmail 50,
     google 59 tests; tsc clean; `plot build` 275KB. ⚠️ Multi-product write-back routing: Mail gates on
     `meta.threadId`/`type==="email"` → safe no-op for non-mail; **`onCreateLink` must route by `draft.type`
     once Tasks lands** (Tasks also has onCreateLink).
   - **Tasks — ✅ DONE** (commit `01bdae0` on `connector-google-clean`, pushed → extends **#222**). Extracted
     google-tasks sync/poll/write-back → `google-tasks/src/sync.ts` over a `TasksSyncHost` (polling, no
     webhooks); combined `Google` wires it via `makeTasksHost()` (`tasks:` namespaced) + `onTasksChannelEnabled`
     + `tasksSyncBatch`/`tasksPeriodicSync`/`tasksPeriodicSyncBatch` (recurring `poll:<listId>`). **`onCreateLink`
     now routes by `draft.type`** (`task`→Tasks, else→Mail); `onLinkUpdated` is Tasks-only. `activate()` also
     seeds `tasks:auth_actor_id`; `build()` adds the Tasks API URL. Verified: tasks+gmail tsc clean, google 59
     tests, `plot build` 283KB.
   - **Contacts — ✅ DONE** (commit `e2e02b2` on `connector-google-clean`, pushed → extends **#222**). Extracted
     google-contacts' read-only contact-import → `google-contacts/src/sync.ts` over a `ContactsSyncHost`
     (channelless, no webhooks/poll/write-backs); combined `Google` wires it via `makeContactsHost()`
     (`contacts:` namespaced) + `onContactsChannelEnabled` + `contactsSyncBatch`. The `GoogleContacts` public
     enrichment TOOL API (`getContacts`/`startSync`/`stopSync` + `enrichLinkContactsFromGoogle`) is unchanged.
   - **✅ PHASE 3 COMPLETE** — Mail + Calendar + Tasks + Contacts sync all re-homed into the one combined
     connector; every product's `onEnable`/`onDisable` is now intercepted by `Google.onChannelEnabled/Disabled`
     (no more `Phase 3` throws). Final verify: gmail 50 + google-calendar 38 (guardrails) + google 59 tests;
     all four packages tsc clean; `plot build` 289KB. #222 now carries the COMPLETE connector (Calendar + Mail
     + Tasks + Contacts). **Remaining: catalog cutover + bankruptcy migration (Phase 4/6, deploy/DB-gated).**
5. **Phase 4 catalog cutover** (one source replaces the three legacy Google sources) + **Phase 6 bankruptcy
   migration** (archive old twist_instances, prompt re-add). Deploy/DB-gated — **RUNBOOK AUTHORED**:
   `docs/superpowers/plans/2026-06-24-google-composite-cutover-runbook.md`. Key finding: this is NOT an
   auto-migration (Atlas applies once on next deploy of every env → would fire bankruptcy before the connector
   deploy + app prompt; no guard survives a one-shot migration) — it's a **manual, coordinated prod SQL op**.
   Sequence: (1) `plot deploy` combined connector to prod (creates the catalog `twist` row; safe early — sits
   alongside the 3 legacy ones), (2) release app w/ re-add prompt, (3) run the bankruptcy SQL (archive 3 legacy
   `twist` rows + their user `twist_instance`s via `archived_at=now()`, keyed on stable `twist_package_id`s;
   `seq` auto-bumps → clients re-sync), (4) verify catalog shows ONE Google source + 0 active legacy instances,
   (5) verify re-add convergence (same globally-unique `source` keys → upsert converges, no dup threads). SQL
   validated against worktree DB (parses, correct cols; 0 rows locally since legacy connectors aren't deployed
   to dev). ⚠️ Pre-req: **confirm combined `plotTwistId` 6e9e441f-… is FINAL** before prod deploy (was a Phase-2
   placeholder). **Remaining code piece: the re-add prompt** (Flutter banner on Connections screen, data-driven
   from archived legacy Google instances — buildable + widget-testable; spec'd in the runbook, NOT yet built).

## Human-gated verification checklist (batch these — I can't do them headless)
- [ ] `plot login` token still valid for local deploys (re-run if deploys 401).
- [ ] A Google account connected to the local combined connector (OAuth = browser).
- [ ] Confirm a real calendar event **backfills** as a thread (done? re-confirm after live-update work).
- [ ] After step 1: confirm a calendar change **updates** the thread live, and an **RSVP** set in Plot
      round-trips to Google.
- [ ] Contacts logo: live at `plot.day/assets/logo-google-contacts.png` only after the next `apps/site`
      deploy (blank locally until then — accepted).
- [ ] **(PR #430)** After connect, confirm all granted products read **ON**; toggling a granted product is
      local (no "Continue with Google"); a not-granted product still stages the re-auth.

## Orchestration model
Background subagent does the heavy file work → its short report is the only thing that enters the
controller's context → controller verifies on the local worker (`tsc`/vitest/`plot build`/deploy) → commits
→ PRs each shippable chunk → updates this doc + the memory file. Keep this doc current as the resume anchor.
