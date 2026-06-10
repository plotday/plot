# Single-Panel Five-Tab Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the single-panel (mobile/narrow) bottom navigation into five real, persistent tabs — Threads, Agenda, New, Search, More — each with its own navigation stack, and standardize the back/close affordances across every page.

**Architecture:** Additive expansion of the existing `AutoTabsRouter` in `PrioritiesShell`. The working tab stacks (0 = Priorities/focus list, 1 = Agenda, 2 = Activity/priority+thread) stay intact. We add three new tab stacks — **New** (index 3), **Search** (index 4), **More** (index 5) — and rewire the bottom-nav handlers from "push route / inline toggle / open modal" to `setActiveIndex`. A universal "tap the active tab → pop its stack to root" idiom replaces the old per-slot ad-hoc behaviors. ThreadPage continues to hide the bar via the existing path-depth chrome flag. Multi-panel (desktop) is unchanged — it never shows the bar and keeps Settings as a modal.

**Tech Stack:** Flutter, `auto_route` (with `AutoTabsRouter`), `flutter_bloc`, `forui`. No `flutter/material.dart`. Drift (only if any persisted nav state is added — none is planned). Lint: `cd apps/plot && flutter analyze`. Run/drive: the `run-app` skill.

---

## Locked design decisions

From the design discussion (all confirmed by the user):

| Concern | Decision |
|---|---|
| Threads tab root | Focus list → PriorityPage (`+`visible back button) → ThreadPage. Back returns to the focus list. (Already implemented via cross-tab `sourceTab`; we add the visible button.) |
| After Send (New) | Switch to the Threads tab and open the created thread full-screen (bar hidden). New tab resets to step 1. |
| Search | **Search tab only** in single-panel. Remove the single-panel inline header-search toggle. (Multi-panel keeps its header search — it has no bottom bar.) |
| Open thread from Search/Agenda | Stay in the originating tab; back returns to the search results / agenda. |
| In-progress New draft when leaving via another tab | Preserved (resume on return); never lose typing. |
| Tap the already-active tab | Pop that tab's stack to its root (collapse New to step 1, exit deep settings, etc.). |
| Deep links / notification thread-opens (no originating tab) | Open full-screen; back → Threads tab. |
| Agenda | Stays conditional on a calendar connection; tab set is 4 or 5 items; indices computed dynamically. |
| More | Pages on mobile (this plan); **modal on desktop** (unchanged). Leaf confirmations (Sign out, Delete account, Re-sync) stay modal everywhere. |
| Multi-panel | Out of scope — hard guardrail, no desktop regressions. |
| Affordance glyphs | `←` (`PlotIcon.left`) = hierarchical back, top-left, on pushed pages only. `×` (`PlotIcon.close`) = dismiss, reserved for modals only. Tab roots have no header back. |

## Implementation strategy: additive tabs

The current single-panel shell (`lib/widget/priorities_shell.dart`) runs:

```
AutoTabsRouter (homeIndex 0)
  routes: [ PrioritiesRoute(), AgendaShell(), ActivityShell() ]   // indices 0,1,2
```

- **Focus** slot → `setActiveIndex(0)` (focus list)
- **Agenda** slot → `setActiveIndex(1)`
- **New** slot → `_openNewThread` pushes `NewThreadRoute` into the Activity (tab 2) inner router
- **Search** slot → `_openSearch` switches to tab 2 + expands an inline header field
- **More** slot → `ShowSettings()` opens a modal

We **add two tab stacks** and **repurpose New** so all five slots become `setActiveIndex`:

```
AutoTabsRouter (homeIndex 0)
  routes: [
    PrioritiesRoute(),       // 0  Threads (focus list root; tapping a focus cross-navigates to tab 2)
    AgendaShell(),           // 1  Agenda
    ActivityShell(),         // 2  Activity (priority + thread; the working area, also multi-panel)
    SearchShell(),           // 3  Search (NEW)
    MoreShell(),             // 4  More (NEW)
  ]
```

New thread is **not** a persistent browsable tab — it is a transactional flow. We keep it as a route pushed onto the **Activity** stack (its current home, which already wires `PriorityOnlyRoute` underneath so back pops to the priority page), but the bottom-nav **New** slot's highlight and reset semantics are made to behave tab-like. (Rationale: a thread, once sent, must open on Threads with the bar hidden; modelling New as its own `AutoTabsRouter` index would strand the post-send thread in the wrong stack and force cross-tab juggling. Keeping New on the Activity stack means Send → reset → the thread opens in the same stack the bar already treats as Threads-adjacent.) The visible outcome — tapping "New" shows the compose flow, the bar stays, tapping another tab leaves it — is identical.

> **Naming note:** `NavSlot` already exists with order `[agenda?, focuses, search, newThread, more]` (`priorities_shell.dart:29-38`). The displayed labels are "Focus", "Agenda", "New", "Search", "More". This plan keeps the slot enum names but the user-facing first label becomes **"Threads"** (see Task 6). Internally `NavSlot.focuses` still maps to the focus-list tab.

## Route-tree target (real code, `lib/router.dart`)

Add two children to `PrioritiesShellRoute` after the Activity `EmptyShellRoute`:

```dart
// Tab 3: Search — its own stack so results/scroll/query survive tab switches.
AutoRoute(
  page: EmptyShellRoute("SearchShell"),
  path: 'search',
  children: [
    AutoRoute(
      page: SearchRoute.page,
      path: '',
      guards: [AuthGuard(userBloc)],
    ),
  ],
),
// Tab 4: More — settings rendered as pushable pages on mobile.
AutoRoute(
  page: EmptyShellRoute("MoreShell"),
  path: 'more',
  children: [
    AutoRoute(
      page: MoreRoute.page,
      path: '',
      guards: [AuthGuard(userBloc)],
    ),
    // Settings sub-pages are added by Task 5 (Connections, Twists,
    // Notifications, Teams, AI prefs, Linked emails, etc.).
  ],
),
```

`SearchRoute` and `MoreRoute` are new `@RoutePage()` pages created in Tasks 4 and 5. Run `flutter pub run build_runner build` after adding them so `router.gr.dart` regenerates (never hand-edit the `.gr.dart` file).

## File structure

**New files:**
- `lib/page/search.dart` — `SearchPage` (`@RoutePage(name: 'SearchRoute')`), the global single-panel search tab root.
- `lib/page/more.dart` — `MorePage` (`@RoutePage(name: 'MoreRoute')`), the single-panel settings tab root, plus the settings sub-pages (or one sub-page host that renders a `CommandGroup` as a list).
- `lib/widget/tab_scaffold.dart` — `TabScaffold`, a thin shared wrapper giving every tab-root page the same `UnifiedHeader`-style top bar with **no** back (tab roots), so Search/More/Threads share geometry. (Optional — only if the existing `Scaffold`/`UnifiedHeader` can't be reused directly; decide in Task 4.)

**Modified files:**
- `lib/router.dart` — add `SearchShell`/`MoreShell` children (above).
- `lib/widget/priorities_shell.dart` — tab indices, `navSlotsFor`, `_handleNavTap` (all slots → `setActiveIndex` + tap-active-pops-root), `_currentNavIndex`, `_isFullScreenRoute`, `_openNewThread` (post-send wiring lives in Task 7), remove `_openSearch`'s inline path.
- `lib/page/priority.dart` — `PriorityPage` gains a visible single-panel back button in its header region (Task 3); `PriorityOnlyPage`'s `PopScope` back target unchanged.
- `lib/widget/unified_header.dart` — leading-slot back affordance standardization (Task 6); remove single-panel inline search registration once Search is a tab (Task 4).
- `lib/page/new_thread.dart` — internal step back chevrons routed through the shared leading slot; post-send → open thread on Threads tab (Task 7).
- `lib/command/settings.dart` — `ShowSettings` stays for desktop/modal; expose its `CommandGroup` structure for `MorePage` to render as pages (Task 5).
- `lib/state/layout.dart` — only if the search-toggle registration is removed for single-panel (Task 4); leave multi-panel paths intact.

## Phase overview (each phase independently shippable)

1. **Shell foundation** — add Search/More tab stacks + placeholder roots; rewire all five nav slots to `setActiveIndex`; universal tap-active-pops-root; preserve dynamic Agenda + bar-hide. App compiles and every tab switches; Search/More show a minimal scaffold.
2. **PriorityPage visible back button** — add the `←` in the single-panel priority header that pops to the focus list (mirrors the existing gesture/`sourceTab` behavior).
3. **Search tab content** — build the global `SearchPage`; remove the single-panel inline header-search toggle; opening a result stays in the Search tab.
4. **More tab content** — render settings as pushable pages on mobile; keep modal on desktop; leaf confirmations stay modal.
5. **New post-send + tab semantics** — Send switches to Threads and opens the new thread; New resets to step 1; draft preserved across tab switches; tap-active New pops to step 1.
6. **Header consistency sweep** — every pushed page's leading affordance routed through one `UnifiedHeader` leading slot; `←` for back, `×` for modals only; new-thread step chevrons unified.

> **Scope check (per writing-plans):** This spans several subsystems (shell routing, search, settings, compose). It is delivered as the six sequential phases above; each leaves the app working and testable. Phases 3–5 touch large files (`new_thread.dart`, `settings.dart`, `unified_header.dart`) whose exact current contents should be **read at the start of the phase** — those tasks begin with an explicit read step and a precise spec, rather than pre-baked diffs that could drift from the live source.

---

## Phase 1 — Shell foundation

**Goal:** Five real tab stacks; all bottom-nav slots use `setActiveIndex`; tapping the active tab pops its stack to root. Search/More render a minimal placeholder scaffold so the app compiles and runs. No behavior regressions in Threads/Agenda/New.

### Task 1.1: Add Search/More tab stacks to the router

**Files:**
- Modify: `lib/router.dart:207-268` (inside `PrioritiesShellRoute` children, after the Activity `EmptyShellRoute`)
- Create: `lib/page/search.dart`
- Create: `lib/page/more.dart`
- Modify: `lib/page/page.dart` (barrel export — add `search.dart`, `more.dart` if the barrel lists pages; verify by reading it)

- [ ] **Step 1: Create a minimal `SearchPage` placeholder**

`lib/page/search.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/widget/scaffold.dart';

@RoutePage(name: 'SearchRoute')
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Placeholder — Phase 3 replaces the body with the global search UI.
    return const Scaffold(
      header: null,
      body: Center(child: Text('Search')),
    );
  }
}
```

- [ ] **Step 2: Create a minimal `MorePage` placeholder**

`lib/page/more.dart`:

```dart
import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/widget/scaffold.dart';

@RoutePage(name: 'MoreRoute')
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    // Placeholder — Phase 4 replaces the body with the settings list.
    return const Scaffold(
      header: null,
      body: Center(child: Text('More')),
    );
  }
}
```

> Read `lib/widget/scaffold.dart` first to confirm the `Scaffold` constructor signature (`header`, `body`, `childPad`, `scrollable`, `translucent` are used elsewhere). Adjust the placeholder to satisfy required params.

- [ ] **Step 3: Add the two shell children in `router.dart`**

In `lib/router.dart`, immediately after the Activity `EmptyShellRoute("ActivityShell")` block closes (after line 268's `),`), insert the `SearchShell` and `MoreShell` `AutoRoute`s exactly as shown in "Route-tree target" above.

- [ ] **Step 4: Export the new pages from the page barrel**

Read `lib/page/page.dart`. If it re-exports page files, add `export 'search.dart';` and `export 'more.dart';` in the existing alphabetical/grouped position. If pages are imported individually elsewhere, skip.

- [ ] **Step 5: Regenerate the router**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: `router.gr.dart` regenerates with `SearchRoute` and `MoreRoute` classes; no errors.

- [ ] **Step 6: Verify it analyzes**

Run: `cd apps/plot && flutter analyze`
Expected: No new errors. (`SearchRoute`/`MoreRoute` now resolve.)

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/router.dart apps/plot/lib/router.gr.dart apps/plot/lib/page/search.dart apps/plot/lib/page/more.dart apps/plot/lib/page/page.dart
git commit -m "feat(app): add Search and More tab stacks to single-panel shell"
```

### Task 1.2: Promote all five nav slots to tab indices

**Files:**
- Modify: `lib/widget/priorities_shell.dart` (tab-index constants `21-23`; `navSlotsFor` `32-38`; `AutoTabsRouter.routes` `371-375`; `_handleNavTap` `160-203`; `_currentNavIndex` `136-158`; `_isFullScreenRoute` `122-129`)

- [ ] **Step 1: Add tab-index constants for Search and More**

Replace `priorities_shell.dart:21-23`:

```dart
const int _kTabPriorities = 0;
const int _kTabAgenda = 1;
const int _kTabActivity = 2;
const int _kTabSearch = 3;
const int _kTabMore = 4;
```

- [ ] **Step 2: Add the Search/More routes to `AutoTabsRouter`**

Replace the `routes:` list in `build()` (`priorities_shell.dart:371-375`):

```dart
routes: [
  PrioritiesRoute(),
  EmptyShellRoute("AgendaShell")(),
  EmptyShellRoute("ActivityShell")(),
  EmptyShellRoute("SearchShell")(),
  EmptyShellRoute("MoreShell")(),
],
```

- [ ] **Step 3: Rewire `_handleNavTap` so every slot uses `setActiveIndex`, with tap-active-pops-root**

Replace `_handleNavTap` (`priorities_shell.dart:160-203`). The new version maps each slot to a target tab index, and if the user taps the slot for the **already-active** tab, pops that tab's inner stack to root instead of re-activating:

```dart
void _handleNavTap(
  BuildContext context,
  TabsRouter tabsRouter,
  List<NavSlot> slots,
  int index,
) {
  if (index < 0 || index >= slots.length) return;
  final slot = slots[index];

  // Search is its own tab now; leaving any page should not strand a
  // stale inline-search toggle (multi-panel only registers one).
  if (slot != NavSlot.more && slot != NavSlot.search) {
    LayoutBloc.instance?.requestSearchClose();
  }

  switch (slot) {
    case NavSlot.focuses:
      _switchOrPopToRoot(context, tabsRouter, _kTabPriorities);
      return;
    case NavSlot.agenda:
      _switchOrPopToRoot(context, tabsRouter, _kTabAgenda);
      return;
    case NavSlot.newThread:
      // New stays on the Activity stack (Task 7 owns reset/post-send).
      _openNewThread(context, tabsRouter);
      return;
    case NavSlot.search:
      _switchOrPopToRoot(context, tabsRouter, _kTabSearch);
      return;
    case NavSlot.more:
      _switchOrPopToRoot(context, tabsRouter, _kTabMore);
      return;
  }
}

/// Switches to [targetTab]. If that tab is already active, pops its inner
/// stack to its root instead (the universal "tap active tab = go to root"
/// idiom). Threads/Agenda/Search/More all participate; New is handled by
/// [_openNewThread] (Task 7) because its reset semantics differ.
void _switchOrPopToRoot(
  BuildContext context,
  TabsRouter tabsRouter,
  int targetTab,
) {
  if (tabsRouter.activeIndex == targetTab) {
    final stack = tabsRouter.stackRouterOfIndex(targetTab);
    if (stack != null && stack.canPop()) {
      stack.popUntilRoot();
    }
    return;
  }
  // Bottom-nav switches are "replace" so browser/Cmd+[ history doesn't
  // grow a frame per tab tap (mirrors the prior Focus/Agenda behavior).
  PrioritiesShell.sourceTab = null;
  context.router.root.navigationHistory.markUrlStateForReplace();
  tabsRouter.setActiveIndex(targetTab);
}
```

> `popUntilRoot()` and `canPop()` are `StackRouter` methods in auto_route. Verify the exact names against the installed auto_route version (`grep -r "popUntilRoot\|popUntil" apps/plot/lib` or check the package API). If `popUntilRoot` is absent, use `stack.maybePopTop()` in a loop or `stack.popUntil((route) => route.settings.name == <rootRouteName>)`.

- [ ] **Step 4: Map active tab → nav highlight for Search/More**

Replace the `switch (tabsRouter.activeIndex)` in `_currentNavIndex` (`priorities_shell.dart:149-157`):

```dart
switch (tabsRouter.activeIndex) {
  case _kTabPriorities:
    return slots.indexOf(NavSlot.focuses);
  case _kTabAgenda:
    return slots.indexOf(NavSlot.agenda);
  case _kTabSearch:
    return slots.indexOf(NavSlot.search);
  case _kTabMore:
    return slots.indexOf(NavSlot.more);
  default:
    // Activity tab — no highlight unless on /new (handled above).
    return -1;
}
```

- [ ] **Step 5: Run app and verify five tabs switch**

Use the `run-app` skill. Verify (single-panel window < 1110px wide):
- Tapping Threads/Agenda/New/Search/More each activates its tab.
- Search and More show their placeholder bodies.
- Tapping the active Search tab again is a no-op (root already); tapping active More again is a no-op.
- New still opens the compose flow; Agenda only appears with a calendar connection.

- [ ] **Step 6: Analyze + commit**

Run: `cd apps/plot && flutter analyze` (expect no new errors).

```bash
git add apps/plot/lib/widget/priorities_shell.dart
git commit -m "feat(app): route all five bottom-nav slots through tab indices"
```

### Task 1.3: Confirm bar-hide + multi-panel guardrail still hold

**Files:** none (verification only) — `lib/widget/priorities_shell.dart` `_isFullScreenRoute` and the multi-panel force-to-Activity branch.

- [ ] **Step 1: Verify ThreadPage and /new still hide the bar**

Run app, open a thread (bar hides), open New (bar hides). Confirm `_isFullScreenRoute` (`priorities_shell.dart:122-129`) still matches `/new` and `pathSegments.length >= 3` and `t/…`. Search/More roots are 2-segment paths (`/search`, `/more`) so the bar stays — correct.

- [ ] **Step 2: Verify multi-panel is unaffected**

Resize the window ≥ 1110px. Confirm no bottom nav appears, the working area is the Activity stack, and Settings still opens as a modal (More tab is single-panel only; the modal path via `ShowSettings` is untouched in multi-panel). The `layoutState.multiPanel` branch (`priorities_shell.dart:386-416`) forces `_kTabActivity` and returns `child` with no chrome — Search/More tabs are never surfaced there.

- [ ] **Step 3: Commit (if any guard tweak was needed; otherwise skip)**

---

## Phase 2 — PriorityPage visible back button

**Goal:** In single-panel, the priority feed (PriorityPage, reached by tapping a focus) shows a visible `←` in its header that returns to the focus list — making the existing gesture/`sourceTab` back behavior discoverable. No change to the actual pop target.

**Files:**
- Modify: `lib/widget/unified_header.dart` (the single-panel header rendered above the priority page in `priority.dart:221`) — add an optional leading back affordance.
- Possibly Modify: `lib/page/priority.dart` — pass a "show back" flag / callback into the header when the priority is not a tab root.

> **Read first:** `lib/widget/unified_header.dart` in full, and the `UnifiedHeader()` usage at `priority.dart:221`. Identify the leading slot and how the header knows its context (single vs multi-panel, priority vs thread). The Explore notes say `UnifiedHeader` has `single`/`sidebar`/`main` variants and a fixed 44px height with a leading slot already used for an "open sidebar" toggle.

- [ ] **Step 1: Determine the back action**

The pop target already exists in `PriorityOnlyPage`'s `PopScope.onPopInvokedWithResult` (`priority.dart:695-713`): it computes `computeBackTabFromPriority(...)` and calls `AutoTabsRouter.of(context).setActiveIndex(back.targetTab)`. The visible button must trigger the **same** path so gesture-back and button-back are identical. Extract that body into a reusable method, e.g. on `PriorityShortcutsProviderState` or a free function:

```dart
// In priority.dart — a single entry point both the PopScope and the
// header button call.
void returnFromPriorityToSourceTab(BuildContext context) {
  final back = computeBackTabFromPriority(
    currentSourceTab: PrioritiesShell.sourceTab,
  );
  PrioritiesShell.sourceTab = back.nextSourceTab;
  AutoTabsRouter.of(context).setActiveIndex(back.targetTab);
}
```

Replace the inline body in `PopScope.onPopInvokedWithResult` (after the `tryCloseSearch` guard) with a call to `returnFromPriorityToSourceTab(context)`.

- [ ] **Step 2: Show the leading `←` in the single-panel priority header**

In `UnifiedHeader` (or via a parameter passed from `priority.dart`), when single-panel **and** the active inner route is the priority page (not a thread, not `/new`), render a leading `IconButton`/`FButton.icon` with `PlotIcon.left` whose `onPress` calls `returnFromPriorityToSourceTab(context)`. Reuse the existing leading-slot styling (18px muted, matches the new-thread step chevron).

Gate conditions (match `_isFullScreenRoute` semantics so the button only shows where the bar shows and we're one level into the Threads stack):
- `!layoutState.multiPanel`
- current path is `/p/:id` (priority page), i.e. 2 path segments starting with `p` — not `/p/:id/:threadId` (thread, has its own back) and not `/p/:id/new`.

- [ ] **Step 3: Run app + verify**

Single-panel: Threads tab → tap a focus → PriorityPage shows `←` top-left → tapping it returns to the focus list. Confirm gesture-back still does the same. Open a thread from the feed → thread has its own back (not this one). Multi-panel: no change (button hidden).

- [ ] **Step 4: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/page/priority.dart apps/plot/lib/widget/unified_header.dart
git commit -m "feat(app): add visible back button to single-panel priority header"
```

---

## Phase 3 — Search tab content

**Goal:** `SearchPage` is a real global search (across Everything) with results; the single-panel inline header-search toggle is removed; opening a result stays in the Search tab and back returns to the results.

> **Read first:** `lib/widget/unified_header.dart` (search field expand/collapse + `LayoutBloc.requestSearchToggle` registration), `lib/state/priority.dart` (search/`globalViewScope`/`remoteSearchExtras` fields and how results are produced), and how `_GlobalViewSidebar`/`PriorityPage` already render global search results (`priorities.dart:189`, `priority.dart:1081`). The cleanest implementation **reuses** the existing global-search machinery (`PriorityBloc` global view) rather than building a parallel search engine.

### Task 3.1: Build the global SearchPage

- [ ] **Step 1:** Replace the `SearchPage` placeholder body with: a top search field (autofocus on first entry to the tab, **not** on resume) + the global results list. Drive results through the existing `PriorityBloc` global view (the same path multi-panel uses when a query is active: `globalViewScope`, `activityFeedItems`, `remoteSearchExtras`). If `SearchPage` needs a `PriorityBloc`, mount one scoped to the default/root priority (Everything), mirroring how `_openSearch` set `everything: true` today.
- [ ] **Step 2:** Preserve query/results/scroll across tab switches — `AutoTabsRouter` keeps the Search stack alive, so hold query state in the bloc (not a disposed `TextEditingController`), matching `PriorityBloc.state.search`.
- [ ] **Step 3:** Tapping a result opens the thread **within the Search tab** so back returns to results. Use a full-screen thread route pushed onto the Search stack. Prefer reusing `ThreadLookupRoute` (`t/:threadId`, `router.dart:255`) under `SearchShell` so the thread renders full-screen (bar hidden by `_isFullScreenRoute`'s `t/…` branch) and back pops to `SearchRoute`. **Verify** `ThreadLookupRoute` can resolve+render standalone under a non-Activity shell; if it hard-codes Activity assumptions, add a `ThreadRoute`-style child under `SearchShell` instead.
- [ ] **Step 4:** Run app: Search tab → type a query → results across all focuses → tap one → thread opens full-screen → back → results intact → switch to Threads and back to Search → query/results preserved.

### Task 3.2: Remove the single-panel inline header search

- [ ] **Step 1:** In `priorities_shell.dart`, delete `_openSearch` and `_expandSearchWhenReady` (now unused) and the `NavSlot.search` inline-toggle path (already replaced by `_switchOrPopToRoot` in Task 1.2).
- [ ] **Step 2:** In `unified_header.dart` / `priority.dart` / `layout.dart`, **conditionally** disable the inline search field + `requestSearchToggle`/`registerSearchToggle` **for single-panel only**. Multi-panel must keep its header search (it has no bottom bar). Gate the registration on `!multiPanel ? skip : register`. Confirm the `ToggleSearchIntent` keyboard shortcut (`priority.dart:560`, `/`) still works in multi-panel and is harmless (or also routed to the Search tab) in single-panel.
- [ ] **Step 3:** Run app single-panel: confirm the old inline search no longer appears on the priority header; `/` either does nothing or focuses the Search tab. Multi-panel: confirm header search still expands/collapses and filters globally.
- [ ] **Step 4:** Analyze + commit (`feat(app): single-panel search becomes a dedicated tab`).

---

## Phase 4 — More tab content (settings as pages)

**Goal:** `MorePage` renders the settings list as pushable pages on mobile; multi-panel keeps the `ShowSettings` modal; leaf confirmations stay modal everywhere.

> **Read first:** `lib/command/settings.dart` in full — `ShowSettings`, its `CommandGroup`s, and each destination (Connections, Twists, Linked emails, Light/dark, Notifications, AI prefs, Plot AI prefs, Manage subscription, Teams, Help & feedback, Copy/Open page link, Re-sync, Delete account, Version, Sign out). Determine which entries are navigations (open a sub-menu/page) vs leaf actions (toggles, confirms, external). Read `lib/widget/command_modal.dart` to see how command groups render today.

### Task 4.1: Render top-level settings as a list page

- [ ] **Step 1:** Replace `MorePage`'s placeholder with a list built from the **same** `CommandGroup` structure `ShowSettings` uses (single source of truth — do not duplicate the list). Each row: icon + title + subtitle, matching the modal's rows. Tapping a **navigation** entry pushes a settings sub-page onto the More stack (`←` back via Phase 6 leading slot). Tapping a **leaf** entry runs the command in place (toggles) or opens a `ConfirmModal` (Sign out, Delete account) / external action (Help & feedback, Copy link) — these stay modal.
- [ ] **Step 2:** For sub-destinations that are themselves command groups (e.g. Connections, Twists, Teams), create a generic `SettingsGroupPage` (`@RoutePage`) that takes a group identifier and renders that group's commands as a list — so adding settings pages is data-driven, not one page per destination. Add its route under `MoreShell` in `router.dart` and regenerate.
- [ ] **Step 3:** Keep `ShowSettings()` (the modal) for **multi-panel** unchanged — `LeftPanelFooter` (`priorities.dart:351`) and any desktop entry points still call it. Only the single-panel **More** bottom-nav slot routes to the `MorePage` tab.

### Task 4.2: Verify both presentations

- [ ] **Step 1:** Single-panel: More tab → list of settings → tap Connections → sub-page with `←` back → back returns to the More root. Toggle Light/dark in place. Sign out → ConfirmModal.
- [ ] **Step 2:** Multi-panel: Settings still opens as the modal (no tab). No regression.
- [ ] **Step 3:** Analyze + commit (`feat(app): render More as settings pages in single-panel`).

---

## Phase 5 — New thread tab semantics + post-send

**Goal:** Send switches to the Threads tab and opens the created thread full-screen; the New flow resets to step 1; an in-progress draft is preserved when leaving via another tab; tapping the active New slot pops to step 1.

> **Read first:** `lib/page/new_thread.dart` — `NewThreadPageState`, `requestReset()`/`resetRequest` (`priorities_shell.dart:275` calls `NewThreadPageState.requestReset()`), the `_ComposeStep` state machine (sections → connection → compose), and the Send handler / `CommandDone`. Identify where a thread id becomes available after send.

### Task 5.1: Post-send opens the thread on Threads

- [ ] **Step 1:** On successful Send, capture the created thread id, then navigate so the thread opens in the **Activity/Threads** stack full-screen. Reuse the existing thread-open command (`ChangeCurrentThread`) or push `ThreadRoute`/`ThreadLookupRoute`. Because New already lives on the Activity stack with `PriorityOnlyRoute` beneath, the natural result is: `/p/:pid/new` → replace with `/p/:pid/:threadId`, so back from the thread lands on the priority feed (Threads). Confirm the bottom bar shows the Threads context after, not "New" highlighted.
- [ ] **Step 2:** Reset the New flow to step 1 after send (`NewThreadPageState.requestReset()` already exists — ensure it fires post-send so the next "New" tap is fresh).
- [ ] **Step 3:** Run app: compose → Send → the new thread opens full-screen → back → Threads feed (the priority it was filed to). Tap New again → fresh step 1.

### Task 5.2: Draft preservation + tap-active-pops-root for New

- [ ] **Step 1:** Leaving New via another tab (without sending) must preserve the draft. The page already persists because the Activity stack stays alive; confirm that switching Threads↔New mid-compose resumes the typed note. (If `requestReset()` is being fired on entry, gate it so it only fires on an explicit fresh-New tap, not on tab resume.)
- [ ] **Step 2:** Tapping the **New** slot while already on `/new` should reset to step 1 (the user's "start over"). In `_openNewThread`, when the current inner route is already `NewThreadRoute`, call `NewThreadPageState.requestReset()` instead of pushing again. (Today `_openNewThread` guards `innerRouter.current.name != NewThreadRoute.name` to avoid double-push — extend the else branch to reset.)
- [ ] **Step 3:** Run app: mid-compose → Threads → New → draft resumes. Tap New again while composing → resets to step 1.
- [ ] **Step 4:** Analyze + commit (`feat(app): new-thread post-send opens thread; tab-aware reset`).

---

## Phase 6 — Header consistency sweep

**Goal:** One leading-slot affordance system across every page. `←` (`PlotIcon.left`) = hierarchical back, top-left, on pushed pages only (thread, new-thread steps 2–3, settings sub-pages, priority page). `×` (`PlotIcon.close`) = dismiss, modals only. Tab roots (Threads focus list, Agenda, Search, More, New step 1) show no header back. All routed through `UnifiedHeader`'s leading slot so geometry is pixel-identical.

> **Read first:** `lib/page/new_thread.dart` step header (`compose_sections_view.dart:571`, `connection_picker_view.dart:206` — chevrons currently inside the search-field leading slot), `lib/page/thread.dart` `_ThreadActionsRow`, and `lib/widget/modal.dart` `_ModalCloseButton` (the `×`).

- [ ] **Step 1:** Audit every page's top-left affordance. Produce a checklist: Threads list (none), PriorityPage (`←`, Phase 2), ThreadPage (`←`), New step 1 (none — tab root; leave via bar), New steps 2–3 (`←`), Search root (none), Search→thread (`←`), More root (none), More sub-pages (`←`), modals (`×` top-right only).
- [ ] **Step 2:** Move the new-thread step chevrons (`compose_sections_view.dart`, `connection_picker_view.dart`) **out of the search-field `leading` slot** into the shared header leading slot so they sit in the exact position as the thread/priority back arrow. New **step 1** loses its in-field chevron entirely (it's a tab root; the bar is the exit).
- [ ] **Step 3:** Confirm `×` (`PlotIcon.close`) appears **only** in `modal.dart` (`_ModalCloseButton`) and nowhere as a page affordance. Grep: `grep -rn "PlotIcon.close" apps/plot/lib` and verify every hit is a modal/overlay dismiss.
- [ ] **Step 4:** Confirm `←` (`PlotIcon.left`) usages are all top-left header backs. Grep and verify.
- [ ] **Step 5:** Run app and walk every page; confirm the leading affordance lands in the same position and behaves per the checklist. Pay attention to the previously-missing **new-thread compose step** back affordance (the original bug report) — it must now show `←` returning to the connection/sections step.
- [ ] **Step 6:** If any Font Awesome icon usage changed, bump `FONT_CACHE_VERSION` in `scripts/cache-bust-fonts.sh` (per apps/plot AGENTS.md).
- [ ] **Step 7:** Analyze + commit (`refactor(app): unify header back/close affordances across pages`).

---

## Cross-cutting behaviors (apply throughout)

- **Tab roots never show a header back.** The bar is the exit. Only pushed pages get `←`.
- **`markUrlStateForReplace()` on tab switches** keeps browser/`Cmd+[` history meaningful (preserve the existing pattern from `_handleNavTap`).
- **Agenda stays conditional.** `navSlotsFor(hasCalendar:)` and the bounce-off-agenda guard (`priorities_shell.dart:429`) must keep working with the larger slot set. The Search/More slots are always present; only Agenda is conditional. Verify `slots.indexOf(...)` lookups never assume a fixed Agenda position.
- **Never use `flutter/material.dart`.** forui + `flutter/widgets.dart` only.
- **Error capture:** any new `catch` for an unexpected error calls `Tracker.captureException(error, stackTrace)`. Don't capture expected/handled errors.
- **`/finalize` before declaring done** (lint, backwards-compat, error capture, docs). Add a `docs/updates.md` bullet for the user-facing nav change; update `docs/features.md` if it documents navigation. Update `docs/layout.md` (currently stale — it still describes 2 tabs and `NewActivityRoute` names) to reflect the five-tab single-panel model.

## Verification strategy

Routing/navigation here is integration-level, so verification leans on:
1. `cd apps/plot && flutter analyze` after every task (zero new errors).
2. `flutter pub run build_runner build --delete-conflicting-outputs` after any `@RoutePage` change (regenerates `router.gr.dart`).
3. The **run-app** skill to drive the real app per the per-task "Run app" steps — single-panel (window < 1110px) is the primary surface; verify multi-panel (≥ 1110px) shows no regression after each phase.
4. Where pure logic is extracted (e.g. `_switchOrPopToRoot` decisions, `navSlotsFor`), add a widget/unit test under `apps/plot/test/` asserting the slot→index mapping and the conditional Agenda set.

## Self-review checklist (run before execution)

1. **Spec coverage:** every locked decision maps to a phase — Threads root/back (Ph 2), after-send (Ph 5), search-tab-only (Ph 3), cross-tab back (Ph 3.1 step 3), draft preserve + tap-active-reset (Ph 5.2), deep-link→Threads (Ph 5/6 thread routing), Agenda conditional (cross-cutting), More pages-vs-modal (Ph 4), multi-panel untouched (Ph 1.3), glyphs (Ph 6). ✓
2. **Placeholder scan:** Phases 3–6 use "read first + precise spec" steps by design (large live files); they are not vague TODOs — each names the exact files, functions, and acceptance behavior. Expand each to concrete diffs at the start of that phase, after the read step.
3. **Type/name consistency:** `_kTabSearch=3`, `_kTabMore=4`; `SearchRoute`/`MoreRoute`/`SearchShell`/`MoreShell`; `_switchOrPopToRoot`; `returnFromPriorityToSourceTab`. Verify `popUntilRoot`/`canPop` against the installed auto_route API in Task 1.2 step 3.
```
