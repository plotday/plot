# Hide the agenda when there are no active calendar connections

**Date:** 2026-06-05
**Status:** Approved design — ready for implementation plan

## Problem

The agenda surfaces scheduled events. A user with no calendar connection sees
an empty agenda in two places — the bottom-nav **Agenda** tab (single-panel /
mobile) and the **left-sidebar agenda** (multi-panel / desktop). For those
users the agenda is dead weight. We want to hide it from both the sidebar and
the bottom nav when there are no active calendar connections, and reveal it
live the moment the first calendar is connected.

## Why this needs a design (not just a one-liner)

There is **no first-class signal today** that marks a connection as a
"calendar" connection. The only existing signals are unreliable for this
purpose:

- A hardcoded `twistPackageId` allowlist (Google + Outlook) that lives only in
  onboarding code (`onboarding_calendars.dart`) — not extensible; silently
  wrong for any new calendar connector.
- The string convention `linkType.type == "event"` — an undocumented contract
  that breaks the instant a calendar connector uses a different `type`.
- Inferring from whether `schedule` rows actually exist — data-dependent, so a
  freshly-connected but empty calendar would wrongly hide the agenda.

So reliable detection requires a small, declarative capability flag.

## Decisions (locked)

- **Detection field name:** `includesSchedules` (boolean) on `LinkTypeConfig`.
- **"Active" definition:** connected and not archived. Connections that
  `needsReauth` or are mid `initialSyncing` **still count** (keep the agenda
  visible so the surface where a broken sync shows up is not hidden). Draft
  connections do **not** count.
- **Agenda content is calendar-only in practice.** Nothing else (native/manual
  events, task due-dates, twist-created schedules) puts items on the agenda
  today, so keying visibility purely on calendar connections will not hide user
  data.

## Architecture

### 1. The new signal — `includesSchedules`

**SDK (twister, in `public/` submodule):**

- Add optional `includesSchedules?: boolean` to `LinkTypeConfig` in
  `public/twister/src/tools/integrations.ts`, with JSDoc explaining it marks a
  link type that produces time-anchored schedule/agenda items, and that the
  Flutter app uses it to decide whether to surface the agenda.
- Rebuild twister (`cd public/twister && pnpm build`).
- **Changeset** (minor) at `public/.changeset/<name>.md`:
  `Added: includesSchedules flag on LinkTypeConfig to mark calendar/schedule-producing link types`.

**Connectors (in `public/` submodule)** — set `includesSchedules: true` on the
`event` link type of exactly these three:

| Connector | File | Link type |
|---|---|---|
| google-calendar | `public/connectors/google-calendar/src/google-calendar.ts` | `type: "event"` |
| apple-calendar | `public/connectors/apple-calendar/src/apple-calendar.ts` | `type: "event"` |
| outlook-calendar | `public/connectors/outlook-calendar/src/outlook-calendar.ts` | `type: "event"` |

Explicitly **not** flagged: granola, fellow (attach meeting *notes* to calendar
event threads but do not create schedules), and all task connectors
(google-tasks, todoist, airtable, asana — due-dates, not time-anchored agenda
items). Messaging / issue / doc / CRM connectors are unrelated.

**End-to-end flow is already opaque JSON — no server/DB changes.** Verified
path: connector `linkTypes` → stored in `twist.permissions -> '_providers' ->
'linkTypes'` (jsonb) → `user.twist` view rebuilds via `jsonb_agg` (preserves
unknown fields) → `/sync/twist-instances` returns rows via `selectAll()` →
Flutter `twist_instances.link_types` JSON string. Nothing maps the object
field-by-field, so a new optional field survives untouched.

**Flutter:**

- Add `includesSchedules` (default `false`) to `LinkTypeConfig`
  (`apps/plot/lib/store/link.dart`): the `const` constructor and `fromJson`
  (accept both `includesSchedules` and snake_case `includes_schedules`, matching
  the file's existing dual-key parsing).
- Add reactive + synchronous detection helpers to `TwistInstance`
  (`apps/plot/lib/store/twist_instance.dart`):
  - `static Stream<bool> watchHasCalendarConnection()` — derived from the
    existing `watchSourceAccounts()` (which already filters non-draft / isSource
    / not-archived), mapping to "any source whose `parsedLinkTypes` contains a
    config with `includesSchedules == true`", with `.distinct()`.
  - `static bool get hasCalendarConnectionInCache` — same predicate over the
    in-memory `_cache`, for first-paint `homeIndex` and route-guard checks where
    a synchronous answer is needed.

### 2. Bottom nav (single-panel) — `priorities_shell.dart`

- Replace the hardcoded visual-index constants (`_kNavPriorities`/`_kNavAgenda`/
  `_kBtnNew`/`_kBtnSearch`/`_kBtnMore`) with a small **dynamic slot model** — an
  enum of nav slots and an ordered list built from `hasCalendar`. When there's
  no calendar connection the Agenda slot is omitted and New/Search/More shift
  left automatically. `_buildNavItems`, `_currentNavIndex`, and `_handleNavTap`
  all derive from the slot list (`slots[index]` for taps, `slots.indexOf(slot)`
  for the highlight, `-1` when nothing matches). This retires the fragile
  hardcoded-index scheme.
- Keep the Agenda **tab/route** in the `AutoTabsRouter` — tab indices
  (`_kTabPriorities=0`, `_kTabAgenda=1`, `_kTabActivity=2`) are unchanged. We
  hide only the button.
- Source `hasCalendar` reactively via `StreamBuilder<bool>` /
  `TwistInstance.watchHasCalendarConnection()` inside the existing
  `AutoTabsRouter` builder (alongside the current `BlocBuilder<LayoutBloc>`).
- **Navigation guard:** if there's no calendar connection and the active tab is
  `_kTabAgenda`, switch to `_kTabPriorities` in a post-frame callback — mirrors
  the existing multi-panel force-to-Activity pattern (`priorities_shell.dart`
  ~lines 368–374).
- **`homeIndex`:** use `hasCalendarConnectionInCache ? _kTabAgenda :
  _kTabPriorities` so cold-start lands on Focuses (not Agenda) when there's no
  calendar, avoiding a one-frame flash. The post-frame guard is the reliable
  backstop if the cache is cold at first build.

### 3. Left sidebar agenda (multi-panel) — `priority.dart`

- The `ResizablePanelLayout` at `priority.dart:166` passes
  `leftBottom: const LeftPanelAgendaView()`. Change to
  `leftBottom: hasCalendar ? const LeftPanelAgendaView() : null`, sourced
  reactively (wrap the `ResizablePanelLayout` build, or just the `leftBottom`
  decision, in a `StreamBuilder<bool>`; `.distinct()` keeps rebuilds minimal on
  this hot path).
- With no calendar connection the left column shows only the priorities tree at
  full height. `leftFooter` is already conditionally `null`, so the layout
  supports omitting a left sub-panel — confirm `leftBottom` is declared nullable
  in `ResizablePanelLayout` and collapses cleanly (no empty split / divider).

### 4. Universal `/agenda` route guard — `agenda.dart`

- `AgendaPage.build` already redirects to `RootRoute` in multi-panel. Add an
  equivalent redirect to `/` when there's no calendar connection, so a
  deep-link or saved `/agenda` URL (e.g. single-panel web) doesn't strand the
  user on a now-hidden view. Source the signal reactively (or via the cache,
  with the empty agenda degrading gracefully if the cache is briefly cold).

### 5. Reactivity

All three surfaces subscribe to the same `watchHasCalendarConnection()` stream,
so connecting the first calendar (or removing the last) shows/hides the agenda
live without a restart.

## Components & boundaries

| Unit | Responsibility | Depends on |
|---|---|---|
| `LinkTypeConfig.includesSchedules` (twister + Flutter) | Declarative capability flag | — |
| 3 calendar connectors | Set the flag on their `event` link type | twister type |
| `TwistInstance.watchHasCalendarConnection()` / `hasCalendarConnectionInCache` | Single source of truth for "has active calendar connection" | `watchSourceAccounts`, `parsedLinkTypes`, `_cache` |
| Bottom-nav slot model | Render/handle nav without the Agenda button when hidden | the helper |
| `priority.dart` `leftBottom` gate | Hide sidebar agenda when hidden | the helper |
| `AgendaPage` guard | Redirect `/agenda` when hidden | the helper |

## Testing

- Unit: `LinkTypeConfig.fromJson` round-trips `includesSchedules` (both
  camelCase and snake_case keys; default `false` when absent).
- Unit: the detection predicate — true when a source has an
  `includesSchedules` link type, false for non-calendar sources, false for
  draft/archived.
- `flutter analyze` on changed files (full-app analyze if a non-nullable
  constructor changes — not the case here, the field has a default).
- twister build + `pnpm lint` in affected connector packages.
- run-app verification: agenda hidden from bottom nav + sidebar with no calendar
  connection; appears live after connecting a calendar; `/agenda` deep-link
  redirects when hidden.

## Packaging

- **Public submodule PR** (`public/`): twister field + JSDoc + changeset +
  the 3 connectors. Build twister and the connectors locally first.
- **Core PR**: Flutter changes + `public/` submodule pointer bump (after the
  public PR merges).
- **Docs**: a plain-language `docs/updates.md` bullet.

## Non-goals / deliberate edge cases

- Re-auth-needed calendar connections keep the agenda visible (locked decision).
- Visibility keys on connections, not on whether events exist — an empty
  calendar still shows the agenda.
- A `draft=false`, zero-channel OAuth orphan (the bug fixed separately in
  PR #246) would be treated as a calendar connection and show the agenda. That's
  consistent with "connected at all" and out of scope here.
- Tasks/projects/messages/docs/CRM connectors are unaffected — they don't set
  the flag and don't put items on the agenda in practice.
