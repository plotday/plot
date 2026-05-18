import 'package:auto_route/auto_route.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/util/priority_nav.dart';

void main() {
  group('computeSourceTabAfterPriorityTap', () {
    test('records originating tab when tapped from Priorities (cross-tab)', () {
      final next = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.priorities,
        currentSourceTab: null,
      );
      expect(next, PriorityTabs.priorities);
    });

    test('records originating tab when tapped from Agenda (cross-tab)', () {
      final next = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: null,
      );
      expect(next, PriorityTabs.agenda);
    });

    test('does NOT overwrite source when tapped from Activity (in-tab)', () {
      // User came from Priorities → tapped priority A → tapped priority B
      // while on /p/A. The second tap is in-tab; source should still be
      // Priorities so back from /p/B returns there.
      final next = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.activity,
        currentSourceTab: PriorityTabs.priorities,
      );
      expect(next, PriorityTabs.priorities);
    });

    test('preserves null source when on Activity tab with no prior origin', () {
      // Deep-link arrival to /p/X then in-tab switch to /p/Y. No
      // origin was ever recorded; back from /p/Y should still fall
      // back to Agenda (handled by computeBackTabFromPriority).
      final next = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.activity,
        currentSourceTab: null,
      );
      expect(next, isNull);
    });

    test('handles null activeTabIndex by returning current source unchanged',
        () {
      // Command triggered from outside the PrioritiesShell tree (e.g.
      // a modal overlay) — no tabsRouter ancestor. Don't crash; leave
      // the source unchanged.
      final next = computeSourceTabAfterPriorityTap(
        activeTabIndex: null,
        currentSourceTab: PriorityTabs.agenda,
      );
      expect(next, PriorityTabs.agenda);
    });
  });

  group('computeBackTabFromPriority', () {
    test('returns the recorded source tab and clears it', () {
      final result =
          computeBackTabFromPriority(currentSourceTab: PriorityTabs.priorities);
      expect(result.targetTab, PriorityTabs.priorities);
      expect(result.nextSourceTab, isNull);
    });

    test('returns Agenda when source is null and clears slot', () {
      // Deep-link arrival to /p/X — no source recorded. Back should
      // land on the default tab (Agenda) so the user has a sane
      // recovery instead of exiting the app.
      final result = computeBackTabFromPriority(currentSourceTab: null);
      expect(result.targetTab, PriorityTabs.agenda);
      expect(result.nextSourceTab, isNull);
    });

    test('source from Agenda routes back to Agenda', () {
      final result =
          computeBackTabFromPriority(currentSourceTab: PriorityTabs.agenda);
      expect(result.targetTab, PriorityTabs.agenda);
    });
  });

  group('PriorityTabs', () {
    test('tab indices match the AutoTabsRouter declaration order in '
        'PrioritiesShell', () {
      // Sanity-check the constants so a reorder in priorities_shell.dart
      // doesn't silently break the navigation helpers.
      expect(PriorityTabs.priorities, 0);
      expect(PriorityTabs.agenda, 1);
      expect(PriorityTabs.activity, 2);
    });
  });

  group('isOnActivityTab', () {
    test('returns true when active index is 2', () {
      expect(
        isOnActivityTab(_FakeTabsRouter(activeIndex: 2)),
        isTrue,
      );
    });

    test('returns false when active index is Priorities (0)', () {
      expect(
        isOnActivityTab(_FakeTabsRouter(activeIndex: 0)),
        isFalse,
      );
    });

    test('returns false when active index is Agenda (1)', () {
      expect(
        isOnActivityTab(_FakeTabsRouter(activeIndex: 1)),
        isFalse,
      );
    });

    test('returns false when tabsRouter is null', () {
      expect(isOnActivityTab(null), isFalse);
    });
  });

  group('regression scenarios — full state transitions', () {
    // These tests encode the exact navigation sequences the user has
    // reported breaking. They drive only the pure-logic side of the
    // problem (which tab to record, where back should go) — the
    // integration-level behaviour (auto_route's inner-stack handling
    // for same-priority taps) needs the same-priority fast path in
    // ChangeCurrentPriority to wire the right side effects on top.

    test('/agenda → tap priority A → back → /agenda', () {
      // Fresh app — no source recorded yet.
      int? sourceTab;

      // User taps A while on Agenda (activeIndex=1).
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // Back gesture from /p/A.
      final back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.agenda);
      expect(back.nextSourceTab, isNull);
    });

    test('/priorities → tap A → back → /priorities', () {
      int? sourceTab;
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.priorities,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.priorities);

      final back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.priorities);
    });

    test('/agenda → tap A → bottom-nav Priorities → back exits app', () {
      // After /agenda → tap A, source is Agenda.
      int? sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: null,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // Bottom-nav Priorities clears the source (replace semantics).
      sourceTab = null;

      // (User now on /priorities. Back from here propagates to the
      // outer navigator — outside the priority page so no PopScope. We
      // don't test that here; the case below covers the case where the
      // user proceeds to tap a priority and then backs.)

      // User taps priority from /priorities — source becomes Priorities.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.priorities,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.priorities);

      // Back from /p/X returns to Priorities (not Agenda).
      final back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.priorities);
    });

    test(
        '/agenda → tap A → back → /agenda → tap A (same priority) → '
        'back → /agenda', () {
      int? sourceTab;

      // First tap (cross-tab).
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // First back consumes & clears.
      var back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      sourceTab = back.nextSourceTab;
      expect(back.targetTab, PriorityTabs.agenda);
      expect(sourceTab, isNull);

      // User taps A again from /agenda — same priority, but the source
      // tracker doesn't care about that; just records the origin.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // Second back also returns to Agenda.
      back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.agenda);
    });

    test(
        '/agenda → tap A → in-place to B (while on Activity) → '
        'back → /agenda', () {
      int? sourceTab;

      // First tap from /agenda — cross-tab.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // While on /p/A (Activity tab active), user taps priority B —
      // in-tab navigation should preserve the original Agenda source.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.activity,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda,
          reason:
              'in-tab priority switch must not overwrite the recorded '
              'cross-tab origin');

      // Back from /p/B should still land on /agenda.
      final back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.agenda);
    });

    test('deep-link arrival to /p/X → back falls back to Agenda', () {
      // No prior cross-tab navigation — source slot is null.
      final back = computeBackTabFromPriority(currentSourceTab: null);
      expect(back.targetTab, PriorityTabs.agenda);
      expect(back.nextSourceTab, isNull);
    });

    test(
        '/agenda → switch to /p/A → tap A-scheduled event in agenda → '
        'back → /agenda', () {
      // The tap on a scheduled event for the currently-open priority is
      // the third forever-spinner case. The agenda's tap handler shares
      // the same source-tab tracking as the priority tap, so this
      // sequence drives the same pure-logic surface.
      int? sourceTab;

      // Cross-tab: /agenda → tap priority A → on Activity.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.agenda,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda);

      // In-tab: while on /p/A the user taps an event in the agenda
      // that belongs to A. The agenda tile is mounted under the
      // Activity tab's nav (left-panel agenda in single-panel mode),
      // so `activeTabIndex` is Activity. Source must be preserved.
      sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: PriorityTabs.activity,
        currentSourceTab: sourceTab,
      );
      expect(sourceTab, PriorityTabs.agenda,
          reason:
              'tapping a scheduled event while on the same priority must '
              'not overwrite the recorded Agenda origin');

      // Back from the destination thread page returns to Agenda.
      final back = computeBackTabFromPriority(currentSourceTab: sourceTab);
      expect(back.targetTab, PriorityTabs.agenda);
    });
  });
}

/// Minimal fake of [TabsRouter] that exposes only [activeIndex] — enough
/// for [isOnActivityTab]. The richer [isSamePriorityAtActivityTop] uses
/// [TabsRouter.stackRouterOfIndex] which is harder to fake; that path
/// is covered by manual user testing on Android/macOS.
class _FakeTabsRouter implements TabsRouter {
  _FakeTabsRouter({required this.activeIndex});

  @override
  final int activeIndex;

  // Unused members — implementations elided. Any test that touches
  // them needs a real TabsRouter.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
