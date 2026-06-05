# Hide Agenda Without Calendar Connections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the agenda (bottom-nav tab + left sidebar) when the user has no active calendar connection, and reveal it live when one is connected.

**Architecture:** A new declarative `includesSchedules` flag on `LinkTypeConfig` (twister SDK) marks calendar/schedule-producing link types; the three calendar connectors set it. The flag flows end-to-end as opaque JSON (no server/DB changes). Flutter derives a single reactive `TwistInstance.watchHasCalendarConnection()` signal and uses it to (a) drop the Agenda slot from the bottom nav, (b) omit the sidebar agenda, and (c) redirect the `/agenda` route.

**Tech Stack:** TypeScript (twister + connectors, in the `public/` git submodule), Dart/Flutter (`apps/plot`), Drift, auto_route, flutter_bloc.

---

## Setup (before Task 1)

- **No database migration.** This feature adds no schema; `bash scripts/worktree-db` is **not** needed.
- **Two repos / two PRs.** Changes span the `public/` submodule (twister + 3 connectors) and the core repo (Flutter). The submodule needs its own branch:
  ```bash
  cd public && git checkout -b feat/link-type-includes-schedules && cd ..
  ```
- **Flutter test bootstrap (one-time, required to run any `flutter test`):** generated code and the env asset must exist.
  ```bash
  cd apps/plot
  flutter pub get
  flutter pub run build_runner build --delete-conflicting-outputs
  # If app.env is missing in a worktree, copy it from the main checkout:
  # cp /path/to/main/repo/apps/plot/app.env apps/plot/app.env
  ```
- **Always-available Flutter gate:** `cd apps/plot && flutter analyze` (CI uses `--no-fatal-infos`).

---

## Task 1: twister — add `includesSchedules` to `LinkTypeConfig`

**Files:**
- Modify: `public/twister/src/tools/integrations.ts` (the `LinkTypeConfig` type, after `supportsAssignee?: boolean;` at ~line 116)
- Create: `public/.changeset/link-type-includes-schedules.md`

- [ ] **Step 1: Add the typed field with JSDoc**

In `public/twister/src/tools/integrations.ts`, inside the `LinkTypeConfig` type, immediately after the `supportsAssignee?: boolean;` line, add:

```typescript
  /**
   * Whether this link type produces time-anchored schedule/agenda items
   * (i.e. calendar events). The Plot app shows the agenda (the bottom-nav
   * tab on mobile and the left-sidebar agenda on desktop) only when the
   * user has at least one active connection whose link types include one
   * with `includesSchedules: true`. Calendar connectors (Google / Apple /
   * Outlook Calendar) set this on their `event` link type. Defaults to
   * false — non-calendar link types (messages, issues, tasks, docs) omit it.
   */
  includesSchedules?: boolean;
```

- [ ] **Step 2: Create the changeset**

Create `public/.changeset/link-type-includes-schedules.md` with exactly:

```markdown
---
"@plotday/twister": minor
---

Added: includesSchedules flag on LinkTypeConfig to mark calendar/schedule-producing link types (drives agenda visibility in the Plot app)
```

- [ ] **Step 3: Validate the changeset**

Run: `cd public && pnpm validate-changesets`
Expected: passes (no errors about the new changeset).

- [ ] **Step 4: Build twister**

Run: `cd public/twister && pnpm build`
Expected: build succeeds (the new optional field type-checks).

- [ ] **Step 5: Refresh the workspace link in the core repo**

Run: `cd /Users/kris.braun/code/plot && pnpm install`
Expected: completes; `@plotday/twister` workspace link now exposes the new field.

- [ ] **Step 6: Commit (in the submodule)**

```bash
cd public
git add twister/src/tools/integrations.ts .changeset/link-type-includes-schedules.md
git commit -m "feat(twister): add includesSchedules flag to LinkTypeConfig"
cd ..
```

---

## Task 2: Connectors — set `includesSchedules: true` on the three calendar connectors

**Files:**
- Modify: `public/connectors/google-calendar/src/google-calendar.ts:183` (inside the `event` link type)
- Modify: `public/connectors/apple-calendar/src/apple-calendar.ts:101` (inside the `event` link type)
- Modify: `public/connectors/outlook-calendar/src/outlook-calendar.ts:158` (the one-line `event` link type)

- [ ] **Step 1: google-calendar**

In `public/connectors/google-calendar/src/google-calendar.ts`, inside the `event` object of `readonly linkTypes`, add `includesSchedules: true,` right after the `sharingModel: "thread" as const,` line:

```typescript
      type: "event",
      label: "Event",
      sharingModel: "thread" as const,
      includesSchedules: true,
      logo: "https://api.iconify.design/logos/google-calendar.svg",
```

- [ ] **Step 2: apple-calendar**

In `public/connectors/apple-calendar/src/apple-calendar.ts`, inside the `event` object, add the field after `sharingModel`:

```typescript
      type: "event",
      label: "Event",
      sharingModel: "thread" as const,
      includesSchedules: true,
      logo: "https://plot.day/assets/logo-apple-calendar.svg",
```

- [ ] **Step 3: outlook-calendar**

In `public/connectors/outlook-calendar/src/outlook-calendar.ts:158`, add `includesSchedules: true,` to the inline `event` object:

```typescript
  readonly linkTypes = [{ type: "event", label: "Event", sharingModel: "thread" as const, includesSchedules: true, logo: "https://api.iconify.design/logos/microsoft-icon.svg", logoDark: "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4", logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg" }];
```

- [ ] **Step 4: Type-check each connector**

```bash
cd public/connectors/google-calendar && pnpm exec tsc --noEmit && cd -
cd public/connectors/apple-calendar && pnpm exec tsc --noEmit && cd -
cd public/connectors/outlook-calendar && pnpm exec tsc --noEmit && cd -
```
Expected: each exits 0 (the field is recognised from the rebuilt twister types).

- [ ] **Step 5: Commit (in the submodule)**

```bash
cd public
git add connectors/google-calendar/src/google-calendar.ts \
        connectors/apple-calendar/src/apple-calendar.ts \
        connectors/outlook-calendar/src/outlook-calendar.ts
git commit -m "feat(connectors): mark calendar event link types includesSchedules"
cd ..
```

---

## Task 3: Flutter — `LinkTypeConfig.includesSchedules` (TDD)

**Files:**
- Test: `apps/plot/test/store/link_test.dart` (existing `LinkTypeConfig.fromJson` group)
- Modify: `apps/plot/lib/store/link.dart` (field + constructor + `fromJson`)

- [ ] **Step 1: Write the failing tests**

In `apps/plot/test/store/link_test.dart`, add these tests inside the existing `group('LinkTypeConfig.fromJson', ...)`:

```dart
    test('parses includesSchedules (camelCase)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'event',
        'label': 'Event',
        'includesSchedules': true,
      });
      expect(cfg.includesSchedules, isTrue);
    });

    test('parses includes_schedules (snake_case)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'event',
        'label': 'Event',
        'includes_schedules': true,
      });
      expect(cfg.includesSchedules, isTrue);
    });

    test('includesSchedules defaults to false when absent', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'note', 'label': 'Note'});
      expect(cfg.includesSchedules, isFalse);
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/store/link_test.dart`
Expected: FAIL — compile error "The getter 'includesSchedules' isn't defined for the type 'LinkTypeConfig'".

- [ ] **Step 3: Add the field**

In `apps/plot/lib/store/link.dart`, in the `LinkTypeConfig` class, add the field right after `final bool supportsAssignee;`:

```dart
  /// Whether this link type produces time-anchored schedule/agenda items
  /// (calendar events). Drives whether the app surfaces the agenda. Mirrors
  /// `LinkTypeConfig.includesSchedules` in twister. Defaults to false.
  final bool includesSchedules;
```

- [ ] **Step 4: Add the constructor parameter**

In the `const LinkTypeConfig({...})` constructor, after `this.supportsAssignee = false,`, add:

```dart
    this.includesSchedules = false,
```

- [ ] **Step 5: Parse it in `fromJson`**

In `LinkTypeConfig.fromJson`, after the `supportsAssignee:` block (the one ending `false,`), add:

```dart
      includesSchedules:
          json['includesSchedules'] as bool? ??
          json['includes_schedules'] as bool? ??
          false,
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/store/link_test.dart`
Expected: PASS (all tests in the file green).

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/test/store/link_test.dart
git commit -m "feat(store): parse LinkTypeConfig.includesSchedules"
```

---

## Task 4: Flutter — calendar-connection detection on `TwistInstance` (TDD)

**Files:**
- Test: `apps/plot/test/store/twist_instance_calendar_test.dart` (new)
- Modify: `apps/plot/lib/store/twist_instance.dart`

- [ ] **Step 1: Write the failing test for the pure predicate**

Create `apps/plot/test/store/twist_instance_calendar_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('TwistInstance.linkTypesIncludeSchedules', () {
    test('false for null', () {
      expect(TwistInstance.linkTypesIncludeSchedules(null), isFalse);
    });

    test('false when no link type includes schedules', () {
      expect(
        TwistInstance.linkTypesIncludeSchedules(const [
          LinkTypeConfig(type: 'message', label: 'Message'),
          LinkTypeConfig(type: 'issue', label: 'Issue'),
        ]),
        isFalse,
      );
    });

    test('true when a link type includes schedules', () {
      expect(
        TwistInstance.linkTypesIncludeSchedules(const [
          LinkTypeConfig(type: 'message', label: 'Message'),
          LinkTypeConfig(
            type: 'event',
            label: 'Event',
            includesSchedules: true,
          ),
        ]),
        isTrue,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/store/twist_instance_calendar_test.dart`
Expected: FAIL — "The method 'linkTypesIncludeSchedules' isn't defined for the type 'TwistInstance'".

- [ ] **Step 3: Add the predicate + reactive/synchronous helpers**

In `apps/plot/lib/store/twist_instance.dart`, add to the `TwistInstance` class (e.g. just after the `watchSourceAccounts()` method, ~line 244):

```dart
  /// True when [types] contains a link type that produces schedule/agenda
  /// items — i.e. this is a calendar connector. See
  /// `LinkTypeConfig.includesSchedules`.
  static bool linkTypesIncludeSchedules(List<LinkTypeConfig>? types) =>
      types?.any((lt) => lt.includesSchedules) ?? false;

  /// True when this source connection produces schedule/agenda items.
  bool get isCalendarConnection =>
      isSource && linkTypesIncludeSchedules(parsedLinkTypes);

  /// Reactive "does the user have an active calendar connection?" signal.
  ///
  /// Built on [watchSourceAccounts] (already filtered to non-draft,
  /// `isSource`, not-archived — connections needing re-auth or mid
  /// initial-sync still count). Drives agenda visibility across the bottom
  /// nav, the sidebar agenda, and the `/agenda` route. `.distinct()` so
  /// consumers only rebuild when the boolean actually flips.
  static Stream<bool> watchHasCalendarConnection() => watchSourceAccounts()
      .map((sources) =>
          sources.any((t) => linkTypesIncludeSchedules(t.parsedLinkTypes)))
      .distinct();

  /// Synchronous best-effort read of the same signal from the in-memory
  /// [_cache], for first-paint decisions (e.g. bottom-nav `homeIndex`) where
  /// awaiting the stream isn't possible. Re-checks active-connection
  /// criteria because the cache holds draft/archived rows too.
  static bool get hasCalendarConnectionInCache => _cache.values.any(
        (t) =>
            t.isSource &&
            t.archivedAt == null &&
            !t.draft &&
            linkTypesIncludeSchedules(t.parsedLinkTypes),
      );
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/twist_instance_calendar_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/twist_instance.dart \
        apps/plot/test/store/twist_instance_calendar_test.dart
git commit -m "feat(store): add calendar-connection detection to TwistInstance"
```

---

## Task 5: Flutter — bottom-nav slot model + agenda hide/guard (`priorities_shell.dart`)

**Files:**
- Test: `apps/plot/test/widget/nav_slots_test.dart` (new)
- Modify: `apps/plot/lib/widget/priorities_shell.dart`

- [ ] **Step 1: Write the failing test for the slot ordering**

Create `apps/plot/test/widget/nav_slots_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/priorities_shell.dart';

void main() {
  group('navSlotsFor', () {
    test('includes the agenda slot when a calendar is connected', () {
      expect(navSlotsFor(hasCalendar: true), const [
        NavSlot.focuses,
        NavSlot.agenda,
        NavSlot.newThread,
        NavSlot.search,
        NavSlot.more,
      ]);
    });

    test('drops the agenda slot when no calendar is connected', () {
      expect(navSlotsFor(hasCalendar: false), const [
        NavSlot.focuses,
        NavSlot.newThread,
        NavSlot.search,
        NavSlot.more,
      ]);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/nav_slots_test.dart`
Expected: FAIL — `NavSlot` / `navSlotsFor` undefined.

- [ ] **Step 3: Add the slot enum + builder, remove the old visual-index constants**

In `apps/plot/lib/widget/priorities_shell.dart`, **delete** the visual-index constant block (the five `const int _kNav*/_kBtn*` lines, ~lines 25-30) and **replace** it with:

```dart
/// Bottom-nav slots in display order. [agenda] is present only when the user
/// has an active calendar connection (see
/// [TwistInstance.watchHasCalendarConnection]); when absent, New/Search/More
/// shift left automatically and nothing references a stale visual index.
enum NavSlot { focuses, agenda, newThread, search, more }

/// The ordered nav slots for the current state.
List<NavSlot> navSlotsFor({required bool hasCalendar}) => [
      NavSlot.focuses,
      if (hasCalendar) NavSlot.agenda,
      NavSlot.newThread,
      NavSlot.search,
      NavSlot.more,
    ];
```

Keep the tab constants `_kTabPriorities` / `_kTabAgenda` / `_kTabActivity` unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/nav_slots_test.dart`
Expected: PASS.

- [ ] **Step 5: Drive the nav from the slot list (rewrite `_currentNavIndex`, `_handleNavTap`, `_buildNavItems`)**

Replace `_currentNavIndex` with the slot-aware version:

```dart
  /// Maps the active tab + URL to the *visual* nav index by looking up the
  /// target slot in [slots]. Returns -1 when nothing should be highlighted
  /// (thread pages, or the agenda tab while the agenda slot is hidden —
  /// `indexOf` returns -1, which FBottomNavigationBar renders unselected).
  int _currentNavIndex(
    BuildContext context,
    TabsRouter tabsRouter,
    List<NavSlot> slots,
  ) {
    final currentPath = context.router.currentPath;
    if (currentPath.endsWith('/new')) return slots.indexOf(NavSlot.newThread);
    final pathSegments =
        currentPath.split('/').where((s) => s.isNotEmpty).toList();
    if (pathSegments.length >= 3 ||
        (pathSegments.isNotEmpty && pathSegments.first == 't')) {
      return -1;
    }
    switch (tabsRouter.activeIndex) {
      case _kTabPriorities:
        return slots.indexOf(NavSlot.focuses);
      case _kTabAgenda:
        return slots.indexOf(NavSlot.agenda);
      default:
        return -1;
    }
  }
```

Replace `_handleNavTap` with the slot-aware version:

```dart
  void _handleNavTap(
    BuildContext context,
    TabsRouter tabsRouter,
    List<NavSlot> slots,
    int index,
  ) {
    if (index < 0 || index >= slots.length) return;
    final slot = slots[index];
    // Navigating away should leave search closed — but Search/More don't
    // navigate, so they leave it alone.
    if (slot != NavSlot.search && slot != NavSlot.more) {
      LayoutBloc.instance?.requestSearchClose();
    }
    switch (slot) {
      case NavSlot.focuses:
        PrioritiesShell.sourceTab = null;
        context.router.root.navigationHistory.markUrlStateForReplace();
        tabsRouter.setActiveIndex(_kTabPriorities);
        return;
      case NavSlot.agenda:
        PrioritiesShell.sourceTab = null;
        context.router.root.navigationHistory.markUrlStateForReplace();
        tabsRouter.setActiveIndex(_kTabAgenda);
        return;
      case NavSlot.newThread:
        _openNewThread(context, tabsRouter);
        return;
      case NavSlot.search:
        _openSearch(context, tabsRouter);
        return;
      case NavSlot.more:
        ShowSettings().run(context);
        return;
    }
  }
```

Replace `_buildNavItems` with a slot-driven builder (preserving the existing Focuses unread-dot icon and More re-auth icon verbatim):

```dart
  List<FBottomNavigationBarItem> _buildNavItems(
    BuildContext context,
    List<NavSlot> slots,
  ) =>
      slots.map((slot) => _buildNavItem(context, slot)).toList();

  FBottomNavigationBarItem _buildNavItem(BuildContext context, NavSlot slot) {
    switch (slot) {
      case NavSlot.focuses:
        return FBottomNavigationBarItem(
          icon: BlocBuilder<PrioritiesBloc, PrioritiesState>(
            builder: (context, state) {
              final hasUnread = state.priorities.any(
                (p) => p.unread || p.descendants().any((d) => d.unread),
              );
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(PlotIcon.priorities),
                  if (hasUnread)
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 6.0,
                        height: 6.0,
                        decoration: BoxDecoration(
                          color: context.colour.accent.withValues(alpha: 0.7),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          label: _buildNavLabel('Focuses'),
        );
      case NavSlot.agenda:
        return FBottomNavigationBarItem(
          icon: Icon(PlotIcon.agenda),
          label: _buildNavLabel('Agenda'),
        );
      case NavSlot.newThread:
        return FBottomNavigationBarItem(
          icon: Icon(PlotIcon.addNote),
          label: _buildNavLabel('New'),
        );
      case NavSlot.search:
        return FBottomNavigationBarItem(
          icon: Icon(PlotIcon.search),
          label: _buildNavLabel('Search'),
        );
      case NavSlot.more:
        return FBottomNavigationBarItem(
          icon: StreamBuilder<List<TwistConnectionRow>>(
            stream: TwistConnection.watchAll(),
            initialData: const [],
            builder: (context, snap) {
              final needsReauth =
                  (snap.data ?? const []).any((c) => c.needsReauth);
              if (needsReauth) {
                return Icon(
                  PlotIcon.plugCircleExclamation,
                  color: context.theme.colors.destructive,
                );
              }
              return Icon(PlotIcon.menu);
            },
          ),
          label: _buildNavLabel('More'),
        );
    }
  }
```

- [ ] **Step 6: Wire `hasCalendar` into `build()` — slots, guard, and `homeIndex`**

In `build()`, change the `AutoTabsRouter` `homeIndex` so a no-calendar cold start lands on Focuses:

```dart
    return AutoTabsRouter(
      homeIndex: TwistInstance.hasCalendarConnectionInCache
          ? _kTabAgenda
          : _kTabPriorities,
      routes: [
        PrioritiesRoute(),
        EmptyShellRoute("AgendaShell")(),
        EmptyShellRoute("ActivityShell")(),
      ],
```

Then, inside the `BlocBuilder<LayoutBloc, LayoutState>` builder, replace the **non-multiPanel** return (the block currently building `hideNav` / `navIndex` / `_MobileShellChrome`) with a `StreamBuilder<bool>` that supplies the slots, runs the guard, and passes the slot list to the helpers:

```dart
            return StreamBuilder<bool>(
              stream: TwistInstance.watchHasCalendarConnection(),
              initialData: TwistInstance.hasCalendarConnectionInCache,
              builder: (context, snap) {
                final hasCalendar = snap.data ?? false;
                final slots = navSlotsFor(hasCalendar: hasCalendar);

                // Guard: if the agenda is hidden but the user is sitting on
                // the agenda tab (e.g. they removed their last calendar
                // connection while viewing it), bounce to Focuses. Mirrors
                // the multi-panel force-to-Activity pattern above.
                if (!hasCalendar &&
                    tabsRouter.activeIndex == _kTabAgenda) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    if (tabsRouter.activeIndex == _kTabAgenda) {
                      tabsRouter.setActiveIndex(_kTabPriorities);
                    }
                  });
                }

                final hideNav = _isFullScreenRoute(context);
                final navIndex =
                    _currentNavIndex(context, tabsRouter, slots);
                return _MobileShellChrome(
                  showNav: !hideNav,
                  currentIndex: navIndex,
                  onChange: (i) =>
                      _handleNavTap(context, tabsRouter, slots, i),
                  items: _buildNavItems(context, slots),
                  child: child,
                );
              },
            );
```

- [ ] **Step 7: Analyze the file**

Run: `cd apps/plot && flutter analyze lib/widget/priorities_shell.dart`
Expected: no errors (info-level lints tolerated). Confirm there are no remaining references to the deleted `_kNav*`/`_kBtn*` constants.

- [ ] **Step 8: Re-run the slot test + commit**

```bash
cd apps/plot && flutter test test/widget/nav_slots_test.dart
```
Expected: PASS. Then:

```bash
git add apps/plot/lib/widget/priorities_shell.dart \
        apps/plot/test/widget/nav_slots_test.dart
git commit -m "feat(nav): hide bottom-nav agenda when no calendar connection"
```

---

## Task 6: Flutter — gate the left sidebar agenda (`priority.dart`)

**Files:**
- Modify: `apps/plot/lib/page/priority.dart` (the `ResizablePanelLayout` build, ~lines 158-246)

`ResizablePanelLayout.leftBottom` is already `Widget?`, and the layout already collapses the left column to full-height `left` when `leftBottom == null` (`resizable_panel_layout.dart:207`). So this is a conditional, sourced reactively.

- [ ] **Step 1: Wrap the builder body in a `StreamBuilder<bool>` and gate `leftBottom`**

Inside the `BlocBuilder<LayoutBloc, LayoutState>` at `priority.dart:158`, wrap the existing builder body in a `StreamBuilder<bool>` and change only the `leftBottom:` argument. Concretely, the builder becomes:

```dart
            child: BlocBuilder<LayoutBloc, LayoutState>(
              builder: (context, layoutState) {
                return StreamBuilder<bool>(
                  stream: TwistInstance.watchHasCalendarConnection(),
                  initialData: TwistInstance.hasCalendarConnectionInCache,
                  builder: (context, snap) {
                    final hasCalendar = snap.data ?? false;
                    final panelLayout = ResizablePanelLayout(
                      left: PrioritiesPanelContent(),
                      leftBottom: hasCalendar
                          ? const LeftPanelAgendaView()
                          : null,
                      leftFooter: layoutState.multiPanel
                          ? const LeftPanelFooter()
                          : null,
                      middle: PriorityPage(priorityId: priorityId),
                      child: /* ...unchanged BlocSelector → AutoRouter... */,
                    );
                    // ...the remainder of the original builder body is
                    // unchanged, now nested one level deeper: the `Widget
                    // body = layoutState.multiPanel ? panelLayout : ...`
                    // assignment, the multiPanel DecoratedBox wrap, and the
                    // final `return DefaultTextStyle(... child: body);`.
                  },
                );
              },
            ),
```

Only two semantic edits: (a) the `StreamBuilder<bool>` wrapper, and (b) `leftBottom: hasCalendar ? const LeftPanelAgendaView() : null`. Everything from the `child: BlocSelector...` through the final `return DefaultTextStyle(...)` stays byte-for-byte the same, just indented inside the new `builder`.

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/priority.dart`
Expected: no errors (info tolerated).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat(sidebar): hide left-panel agenda when no calendar connection"
```

---

## Task 7: Flutter — guard the universal `/agenda` route (`agenda.dart`)

**Files:**
- Modify: `apps/plot/lib/page/agenda.dart` (`AgendaPage.build`, ~lines 89-124)

`AgendaPage` already redirects to `RootRoute` in multi-panel. Extend the redirect to also fire when there's no calendar connection, so a deep-link / saved `/agenda` URL doesn't strand a single-panel user on a now-hidden view.

- [ ] **Step 1: Restructure `AgendaPage.build` to gate on `hasCalendar`**

Replace the body of `AgendaPage.build` (the outer `BlocBuilder<LayoutBloc, LayoutState>`) with:

```dart
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: TwistInstance.watchHasCalendarConnection(),
      initialData: TwistInstance.hasCalendarConnectionInCache,
      builder: (context, snap) {
        final hasCalendar = snap.data ?? false;
        return BlocBuilder<LayoutBloc, LayoutState>(
          buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
          builder: (context, layoutState) {
            // Redirect away when the agenda shouldn't be shown here:
            //  - multi-panel renders the agenda in the left sidebar, so a
            //    dedicated /agenda page is redundant; bounce through `/`.
            //  - no calendar connection → the agenda is hidden entirely, so
            //    a deep-link/saved /agenda URL must not strand the user.
            if (layoutState.multiPanel || !hasCalendar) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                context.router.replaceAll([const RootRoute()]);
              });
              return const LoadingPage();
            }
            return BlocBuilder<NowBloc, NowState>(
              builder: (context, nowState) {
                if (nowState is! NowLoaded) {
                  return const LoadingPage();
                }
                return PriorityBlocProvider(
                  priority: nowState.defaultPriority,
                  setContext: false,
                  child: const _AgendaBody(),
                );
              },
            );
          },
        );
      },
    );
  }
```

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/agenda.dart`
Expected: no errors (info tolerated).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/agenda.dart
git commit -m "feat(agenda): redirect /agenda route when agenda is hidden"
```

---

## Task 8: Verify, document, and package

**Files:**
- Modify: `docs/updates.md`
- (Repo state) `public/` submodule pointer in the core repo

- [ ] **Step 1: Full app analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors (CI uses `--no-fatal-infos`).

- [ ] **Step 2: Run the new/affected Flutter tests**

Run: `cd apps/plot && flutter test test/store/link_test.dart test/store/twist_instance_calendar_test.dart test/widget/nav_slots_test.dart`
Expected: all PASS.

- [ ] **Step 3: run-app verification (invoke the `run-app` skill)**

Verify in the live app:
- With **no** calendar connection: the bottom nav shows Focuses / New / Search / More (no Agenda); the desktop left column shows only the priorities tree (no sidebar agenda); navigating to `/agenda` redirects to `/`.
- **Connect a calendar** (or flip a seeded calendar connection): the Agenda nav item and sidebar agenda appear **live** without restart.
- With a calendar present, confirm the bottom-nav highlight still tracks correctly across Focuses ↔ Agenda ↔ priority pages, and New/Search/More still work (slot-index remap regression check).

- [ ] **Step 4: Add a user-facing update note**

In `docs/updates.md`, add a bullet to the top (current) section, in plain language:

```markdown
- The agenda now stays out of your way until it's useful — if you haven't connected a calendar, it's hidden from the sidebar and bottom navigation, and appears automatically the moment you connect one.
```

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md
git commit -m "docs(updates): note agenda hides without a calendar connection"
```

- [ ] **Step 6: Run `/finalize`**

Invoke the `finalize` skill and work its checklist (lint, backwards-compat, error capture, docs, public-submodule PR). Notes for this change:
- **Backwards compat:** `includesSchedules` is a new optional field defaulting to `false`; older clients ignore it (agenda behaves as today). No removed/renamed fields. ✅
- **Error capture:** no new `catch` blocks added. ✅

- [ ] **Step 7: Open the public-submodule PR**

Push the `public/` branch and open a PR (twister field + changeset + 3 connectors):

```bash
cd public
git push -u origin feat/link-type-includes-schedules
gh pr create --repo plotday/plot --title "feat: includesSchedules flag for calendar link types" \
  --body "Adds LinkTypeConfig.includesSchedules and sets it on Google/Apple/Outlook Calendar event link types. Drives agenda visibility in the Plot app."
cd ..
```

- [ ] **Step 8: Bump the submodule pointer + open the core PR**

After the public PR merges (or to stage the core PR against the branch), record the submodule pointer and open the core PR:

```bash
git add public
git commit -m "chore: bump public submodule for includesSchedules flag"
git push -u origin <core-branch>
gh pr create --title "feat: hide agenda when no active calendar connections" \
  --body "Hides the agenda (bottom nav + sidebar) and redirects /agenda when the user has no active calendar connection, via the new LinkTypeConfig.includesSchedules flag. Reveals live on connect. No DB migration."
```

---

## Self-review notes

- **Spec coverage:** §1 detection → Tasks 1–4; §2 bottom nav → Task 5; §3 sidebar → Task 6; §4 route guard → Task 7; §5 reactivity → shared `watchHasCalendarConnection()` used by Tasks 5/6/7; §6 packaging/testing/docs → Task 8. Non-goals (re-auth still visible, connection-not-data keying, draft orphan) are encoded in `hasCalendarConnectionInCache` / `watchSourceAccounts` semantics — no separate task needed.
- **Type consistency:** `includesSchedules` (camelCase) is the field everywhere in Dart/TS; `includes_schedules` is accepted only as a snake_case JSON alias. `navSlotsFor({required bool hasCalendar})` and `NavSlot` are referenced identically in Task 5 and the test. `TwistInstance.linkTypesIncludeSchedules` / `watchHasCalendarConnection` / `hasCalendarConnectionInCache` names match across Tasks 4–7.
- **No DB migration**, so no Atlas / `pnpm types` / pgTAP steps — intentional.
