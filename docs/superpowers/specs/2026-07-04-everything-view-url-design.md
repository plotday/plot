# Everything view: its own URL (refresh-stable)

**Date:** 2026-07-04
**Branch:** `everything-view-url`
**Status:** Design — pending review

## Problem

The synthetic "Everything" feed (all threads across the Inbox and every focus,
unscoped and unsectioned) has no identity of its own in the router. Entering it
via `ChangeCurrentPriority.everything()` navigates the route to the default
**Inbox** priority's URL (`/p/:inboxId`) and carries a separate, in-memory
`everything: true` flag (`NowBloc.everything`, mirrored into
`PriorityBloc.everything`).

Because the URL is just the Inbox's URL, the everything-ness lives only in RAM:

- **Refresh / cold load / deep link** re-routes on the path `/p/:inboxId`, which
  loads the *scoped Inbox* — the flag is gone and the user silently drops out of
  Everything into the Inbox feed.
- The same structural weakness (route resolution driving a scoped
  `setPriority(inbox)` that clears `everything`) caused a live bug where opening
  Everything **from a focus** landed on the scoped Inbox. That bug is fixed in
  this branch by a guard (`PriorityBloc.shouldApplyRoutePrioritySwitch`); this
  design removes the root cause so the flag can no longer be lost to routing.

## Goal

Give Everything a real, refresh-stable URL so that reloading or deep-linking to
it stays on Everything. Drop the "piggyback on the Inbox URL + in-memory flag"
hack.

Non-goals (YAGNI):

- No shareable/cross-user semantics. Everything is a per-viewer view (it shows
  each viewer *their own* cross-focus threads), so the URL is for
  refresh/bookmark stability, not sharing.
- No change to Search.
- No persisting Everything as the device-local "last open focus".

## Approach: reserved route segment `/p/everything`

Add a reserved segment value to the existing activity-tab route
(`/p/:priorityId`) rather than a new sibling route. When the segment equals the
reserved word (`everything`), the wrapper mounts the same activity feed page in
Everything mode instead of resolving a priority.

### Why reserved-segment over a dedicated `/everything` route

The activity tab's value is the child route tree under `/p/:priorityId`
(`PriorityOnlyRoute`, `NewThreadRoute`, `ThreadRoute`) plus the
`_PriorityWrapperHost` that keeps the inner navigator alive across switches.
With `/p/everything`, opening a thread is `/p/everything/:threadId` and the
entire child tree + wrapper host is inherited unchanged. A dedicated
`/everything` sibling would have to re-declare and keep those children in sync —
more routing surface, more drift risk — for a URL nobody shares.

No collision risk: real priority ids are fixed-length (~22-char base58); a short
reserved word can never decode-collide, and the wrapper checks the sentinel
*before* base58 parsing.

## Mechanism

### 1. Reserved constant

A named constant (e.g. `kEverythingRouteSegment = 'everything'`) so the sentinel
is defined in one place and shared by the wrapper (detection) and the command
(navigation target).

### 2. `PriorityWrapper` detects the sentinel

`PriorityWrapper.wrappedRoute` currently parses `priorityIdString` → `PriorityId`
and redirects to root on parse failure. New branch, checked **before** parsing:

- If `priorityIdString == kEverythingRouteSegment`: build the wrapper host in
  Everything mode (`priorityId: null`, `everything: true`).
- Else: existing behaviour (parse; scoped focus; redirect on invalid).

### 3. `_PriorityWrapperHost` gains an `everything` flag; `priorityId` nullable

The host takes `priorityId: PriorityId?` plus `bool everything`. Its
`didUpdateWidget` already keys transitions off `priorityIdString`, and
`'everything'` is a distinct string, so focus↔Everything transitions flow
through the existing survive-the-inner-navigator path with no remount.

`_build` mounts:

- `PriorityBlocProvider` with `useDefault: true` (loads the default Inbox as the
  draft home — the priority Everything already files drafts into) and
  `setContext: false` (Everything mode is established explicitly at mount; the
  provider must not publish a scoped Inbox context to `NowBloc`).
- `PriorityPage(priorityId: null)` and `_PriorityShortcutsProvider(priorityId:
  null)` — both already tolerate a null `priorityId` (the shortcuts provider
  short-circuits on null; the page uses it only as a scroll-storage-key
  fallback, which is null in Everything today anyway).

### 4. Establish Everything mode at mount (the refresh-safe hook)

On a cold `/p/everything` load nothing has set `NowBloc.everything` yet, so the
mounted feed must establish it — exactly as `_SearchView.initState` calls
`context.read<PriorityBloc>().setEverything(true)` for the spanning search feed.

In Everything mode the feed view, on mount, sets:

- `PriorityBloc.setEverything(true)` — bloc enters `{context: null, everything:
  true}`, re-aims the draft at the Inbox fallback, and restarts the feed
  subscription unscoped/flat.
- `NowBloc.everything = true` — so the sidebar highlights Everything and the
  page's existing `NowBloc.everything` → `PriorityBloc.setEverything` mirror
  stays consistent.

This is the single source of truth: whether the user tapped Everything or
refreshed the page, the same mount path establishes the mode.

### 5. `ChangeCurrentPriority.everything()` navigates to the sentinel

The command's route target becomes `PriorityRoute(priorityIdString:
kEverythingRouteSegment)` instead of the resolved Inbox id. It still flips
`NowBloc.everything = true` up front for instant sidebar highlight (unchanged),
so there is no visible latency waiting for the route mount.

### 6. Guard retained as defense-in-depth

`PriorityBloc.shouldApplyRoutePrioritySwitch` (added in this branch) stays. With
the URL as the source of truth the clobber can no longer originate from route
resolution, but the guard cheaply protects the mirror-vs-route emission ordering
and its tests remain valid.

## Data / control flow

```
Tap Everything (from focus F)                 Cold refresh on /p/everything
────────────────────────────                  ─────────────────────────────
ChangeCurrentPriority.everything()            Router resolves /p/everything
  NowBloc.everything = true (instant)           PriorityWrapper sees sentinel
  navigate → /p/everything                      mount host (everything: true)
PriorityWrapper sees sentinel                       │
  host didUpdateWidget: F → 'everything'            ▼
  mount feed in everything mode              PriorityBlocProvider(useDefault)
       │                                       feed initState:
       ▼                                         setEverything(true)
  feed establishes everything mode               NowBloc.everything = true
  (setEverything(true), NowBloc.everything)          │
                                                     ▼
        both paths converge → {context: null, everything: true}, flat unscoped feed
```

## Components touched

- `apps/plot/lib/router.dart` — no structural change; `/p/:priorityId` already
  covers `/p/everything`. (Confirm `usePathUrlStrategy` — done — so web refresh
  honours the path.)
- `apps/plot/lib/page/priority.dart` — `PriorityWrapper` sentinel branch;
  `_PriorityWrapperHost` gains `everything` + nullable `priorityId`; feed mount
  establishes Everything mode.
- `apps/plot/lib/command/priority.dart` — `ChangeCurrentPriority.everything()`
  targets the sentinel segment; define/share `kEverythingRouteSegment`.
- `apps/plot/lib/state/priority.dart` — retain the guard; minor, if any,
  provider adjustments for the `useDefault + everything` mount.

## Testing

- **Sentinel mapping (unit):** `PriorityWrapper`/segment helper maps
  `'everything'` → Everything-mode mount and any real base58 id → scoped focus;
  invalid id → root redirect (unchanged).
- **Refresh round-trip:** mounting the activity tab at `/p/everything`
  (cold, `NowBloc.everything` starting false) lands in Everything
  (`context == null`, `everything == true`, flat unscoped feed) with no reliance
  on a pre-set flag.
- **Focus → Everything / Everything → focus:** retained coverage, plus the
  existing `shouldApplyRoutePrioritySwitch` guard tests.
- **Draft home:** a thread composed from Everything files into the Inbox
  fallback (existing `priority_everything_context_test` coverage still holds).
- Widget-level test of the mount path if feasible without excessive harness
  (NowBloc + LocalPreferences + Store + identity); otherwise cover the decision
  seams as pure/`@visibleForTesting` predicates (matching
  `shouldApplyWatchedContext` / `shouldApplyRoutePrioritySwitch`).

## Risks / open questions

- **Nullable `priorityId` threading:** the two active consumers already tolerate
  null; the work is relaxing `_PriorityWrapperHost`'s non-null contract and
  auditing any other `widget.priorityId` reads on the everything path.
- **Mount-time emit ordering:** establishing Everything from the feed's
  `initState` (post-provider-mount, Search-style) avoids emitting during a
  parent build. Verify no "emit during build" assert on cold load.
- **`setContext: false` correctness:** Everything must not publish a scoped
  Inbox context to `NowBloc`; it sets `everything` explicitly instead. Confirm
  bottom-nav Activity/New targets still behave (they read `NowBloc.context`,
  which is null in Everything — same as today).
