import 'dart:async' show unawaited;

import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/state/compose_targets.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/router.dart';
import 'package:plot/page/new_thread.dart' show NewThreadPageState;
import 'package:plot/page/search.dart' show SearchPage;
import 'package:plot/store/store.dart';
import 'package:plot/util/priority_nav.dart'
    show
        PriorityTabs,
        computeBackTabFromSecondaryTab,
        highlightTabForActivityPage;
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/thread_header_notifier.dart';

/// Indices into the AutoTabsRouter's `routes`. These identify which
/// inner navigator stack is active. The Activity stack is still where
/// threads and priority pages live even though it no longer has its
/// own bottom-nav button.
const int _kTabPriorities = 0;
const int _kTabAgenda = 1;
const int _kTabActivity = 2;
const int _kTabSearch = 3;
const int _kTabMore = 4;

/// Bottom-nav slots in display order. [agenda] is present only when the user
/// has an active calendar connection (see
/// [TwistInstance.watchHasCalendarConnection]); when absent, New/Search/More
/// shift left automatically and nothing references a stale visual index.
enum NavSlot { focuses, agenda, newThread, search, more }

/// The ordered nav slots for the current state.
List<NavSlot> navSlotsFor({required bool hasCalendar}) => [
      if (hasCalendar) NavSlot.agenda,
      NavSlot.focuses,
      NavSlot.search,
      NavSlot.newThread,
      NavSlot.more,
    ];

/// Returns from a *secondary* bottom-nav tab (Agenda / Search / More) to the
/// tab the user was on before opening it ([PrioritiesShell.previousTab]),
/// falling back to the Focus home tab. Shared by those tabs' back-gesture
/// handlers (via [SecondaryTabBackScope] and the Search tab's inline
/// PopScope) so the back gesture returns inward instead of dropping out of
/// the bottom-nav scope and exiting the app. Consumes (clears) the recorded
/// previous tab. Mirrors [returnFromPriorityToSourceTab] for the Activity
/// stack.
void returnFromSecondaryTab(BuildContext context) {
  final tabsRouter = AutoTabsRouter.of(context);
  final target = computeBackTabFromSecondaryTab(
    currentTab: tabsRouter.activeIndex,
    previousTab: PrioritiesShell.previousTab,
    homeTab: PriorityTabs.priorities,
  );
  PrioritiesShell.previousTab = null;
  tabsRouter.setActiveIndex(target);
}

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget {
  const PrioritiesShell({super.key});

  /// Bottom-nav tab the user was on when they tapped a priority chip that
  /// navigates cross-tab into the Activity stack (`/p/:priorityId`).
  /// Consumed by [PriorityShortcutsProvider]'s back-gesture PopScope to
  /// return to that tab, so the back gesture from a priority page returns
  /// to wherever the user came from (Agenda or Priorities) instead of
  /// dropping out of the bottom-nav scope and exiting the app.
  ///
  /// Bottom-nav taps (Priorities/Agenda) clear this — they "replace" the
  /// view rather than push, so back from a tab-arrival exits cleanly.
  /// Cross-tab navigations from inside the Activity stack (e.g.
  /// switching between priorities while already on `/p/:id`) leave this
  /// untouched so the back gesture still returns to the original origin.
  static int? sourceTab;

  /// The bottom-nav tab the user was on immediately before opening the
  /// *current* secondary tab (Agenda / Search / More). Recorded by
  /// [_PrioritiesShellState._switchOrPopToRoot] on every cross-tab bottom-nav
  /// switch and consumed by those tabs' back-gesture handlers
  /// ([returnFromSecondaryTab]) so back returns to where the user came from
  /// instead of falling through every navigator and exiting the app. A null
  /// value (cold/deep-link arrival) makes back fall back to the Focus home
  /// tab. Distinct from [sourceTab], which tracks Activity-stack drill-ins.
  static int? previousTab;

  /// Opens the new-thread compose flow in **Help & Feedback** mode (Plot-Team
  /// chat filed under the user's Inbox), driving the Activity-tab inner stack
  /// so it works in single- AND multi-panel. The public entry point for the
  /// [HelpAndFeedback] command; delegates to the state's navigation logic
  /// (which doesn't depend on `this`). [rootPriorityIdString] seeds the
  /// Activity-tab PriorityRoute on cold start.
  static void openFeedbackThread(
    BuildContext context,
    String rootPriorityIdString,
  ) => _PrioritiesShellState._openFeedbackThread(context, rootPriorityIdString);

  /// Opens the new-thread compose flow in private-note mode for
  /// [priorityIdString], driving the Activity-tab inner stack so it works
  /// in single- AND multi-panel. The public entry point for the
  /// [NewPrivateNote] command; delegates to the state's navigation logic
  /// (which doesn't depend on `this`).
  static void openPrivateNote(
    BuildContext context,
    String priorityIdString,
  ) => _PrioritiesShellState._openPrivateNote(context, priorityIdString);

  /// Opens a fresh new-thread compose under [priorityIdString], driving the
  /// Activity-tab inner stack directly so it works in single- AND multi-panel.
  /// Used by screenshot scene S5 (which can't reach the private instance flow).
  static void openNewThread(
    BuildContext context,
    String priorityIdString,
  ) => _PrioritiesShellState._openNewThreadStatic(context, priorityIdString);

  /// Opens [threadIdString] (filed under [priorityIdString]) by pushing
  /// ThreadRoute onto the Activity-tab inner stack — the same path a thread tap
  /// uses — so it lands on the thread in single- AND multi-panel even when its
  /// focus is already the current route (a plain `navigate`/`replaceAll` to an
  /// already-mounted PriorityRoute drops the inner child). Used by S2/S7.
  static void openThread(
    BuildContext context,
    String priorityIdString,
    String threadIdString,
  ) => _PrioritiesShellState._openThreadStatic(
        context, priorityIdString, threadIdString);

  /// Public entry for the widget bridge: open a focus (priority) page without
  /// requiring a [BuildContext] from the caller. Resolves context via
  /// [navigatorKey], activates the Activity tab, then navigates to
  /// [PriorityRoute]. Mirrors the [openThread] / [openNewThread] pattern.
  static void openFocus(String priorityIdString) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _PrioritiesShellState._openFocusStatic(ctx, priorityIdString);
  }

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();
}

class _PrioritiesShellState extends State<PrioritiesShell> {
  Listenable? _navHistory;

  @override
  void initState() {
    super.initState();
    // Pre-warm the new-thread step-1 picker. In multi-panel layouts
    // NewThreadPage is always mounted (the right panel), so its picker data
    // loads at app start; in single-panel — this shell — the page isn't
    // mounted until the user taps "New", so without this the first open runs
    // every picker query cold and can take seconds. Warm after the first frame
    // so the focus feed paints first; fire-and-forget (the bloc caches the
    // result, so a later open reuses it).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<ComposeTargetsBloc>().warm().catchError((
          Object e,
          StackTrace s,
        ) {
          Tracker.captureException(e, s);
        }),
      );
    });
  }

  void _onRouteChanged() {
    if (mounted) setState(() {});
  }

  /// Returns the short-string priority id to use when the user invokes
  /// Activity or New from a non-priority route (e.g. `/agenda`). Prefers
  /// the priority the user was last viewing (`NowBloc.context`) and falls
  /// back to the default priority. Returns `null` only while [NowBloc] is
  /// still loading.
  String? _activityPriorityIdString(BuildContext context) {
    final nowState = context.read<NowBloc>().state;
    if (nowState is! NowLoaded) return null;
    final priority = nowState.context ?? nowState.defaultPriority;
    return priority.id.toShortString();
  }

  Widget _buildNavLabel(String text) {
    return Builder(
      builder: (context) {
        final width = MediaQuery.sizeOf(context).width;
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        if (width < 360 * textScale) {
          return const SizedBox.shrink();
        }
        return DefaultTextStyle(
          style: context.theme.typography.xs,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          child: Text(text),
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuild whenever the URL changes so the bottom nav highlight and
    // visibility track the active route — including inner-stack pushes
    // like /p/:id → /p/:id/:threadId that don't change the active tab.
    final history = context.router.navigationHistory;
    if (_navHistory != history) {
      _navHistory?.removeListener(_onRouteChanged);
      _navHistory = history;
      history.addListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    _navHistory?.removeListener(_onRouteChanged);
    super.dispose();
  }

  /// True when the active route is a thread or new-thread page where the
  /// bottom nav should disappear.
  bool _isFullScreenRoute(BuildContext context) {
    final currentPath = context.router.currentPath;
    final pathSegments =
        currentPath.split('/').where((s) => s.isNotEmpty).toList();
    // Standalone thread (/t/:id) always full-screen.
    if (pathSegments.isNotEmpty && pathSegments.first == 't') return true;
    // The new-thread flow KEEPS the bottom bar (it's a top-level tab).
    if (currentPath.endsWith('/new')) return false;
    // A thread under a priority (/p/:id/:threadId — 3+ segments) hides the bar.
    return pathSegments.length >= 3;
  }

  /// Maps the active tab + URL to the visual nav index. Priorities and
  /// Agenda map directly to their bottom-nav slots; the Activity tab no
  /// longer has a bottom-nav button, so it (and any priority page) shows
  /// no highlight. "New" lights up while the user is on `…/new`; thread
  /// pages hide the nav so they have no highlighted index either.
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
      case _kTabSearch:
        return slots.indexOf(NavSlot.search);
      case _kTabMore:
        return slots.indexOf(NavSlot.more);
      default:
        // Activity tab (a /p/:id priority page or its thread list) has no
        // bottom-nav slot of its own. Keep the tab the user drilled in from
        // highlighted — the same tab the back gesture returns to — so the
        // thread list doesn't drop the Focus/Agenda highlight. A deep-link
        // arrival has no recorded origin and stays unhighlighted.
        switch (highlightTabForActivityPage(
          sourceTab: PrioritiesShell.sourceTab,
        )) {
          case _kTabPriorities:
            return slots.indexOf(NavSlot.focuses);
          case _kTabAgenda:
            return slots.indexOf(NavSlot.agenda);
          default:
            return -1;
        }
    }
  }

  void _handleNavTap(
    BuildContext context,
    TabsRouter tabsRouter,
    List<NavSlot> slots,
    int index,
  ) {
    if (index < 0 || index >= slots.length) return;
    final slot = slots[index];

    // Search is its own tab now (tapping it navigates rather than toggling an
    // overlay, so collapsing the inline search would be wrong). More opens a
    // settings page/modal rather than navigating the main content, so it also
    // shouldn't force-close a (multi-panel) inline search. All other slots do
    // navigate away, so any stale inline-search toggle must be dismissed.
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
        // New uses the Activity stack. _openNewThread handles resume vs reset
        // vs fresh-push semantics; after sending, the send path opens the
        // resulting thread on the same Activity stack.
        _openNewThread(context, tabsRouter);
        return;
      case NavSlot.search:
        _switchOrPopToRoot(context, tabsRouter, _kTabSearch);
        // Re-focus the search field on every entry (the kept-alive tab won't
        // re-run its first-mount autofocus).
        SearchPage.requestFocus();
        return;
      case NavSlot.more:
        _switchOrPopToRoot(context, tabsRouter, _kTabMore);
        return;
    }
  }

  /// Switches to [targetTab]. If that tab is already active, pops its inner
  /// stack to its root instead (the universal "tap active tab = go to root"
  /// idiom). Focuses/Agenda/Search/More all participate; New is handled by
  /// [_openNewThread] because its reset semantics differ.
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
    // Remember where we came from so the back gesture out of a secondary tab
    // (Agenda/Search/More) returns here instead of exiting the app. Recorded
    // before the switch so it captures the tab being left.
    PrioritiesShell.previousTab = tabsRouter.activeIndex;
    // Bottom-nav switches are "replace" so browser/Cmd+[ history doesn't
    // grow a frame per tab tap (mirrors the prior Focus/Agenda behavior).
    PrioritiesShell.sourceTab = null;
    context.router.root.navigationHistory.markUrlStateForReplace();
    tabsRouter.setActiveIndex(targetTab);
  }

  void _openNewThread(BuildContext context, TabsRouter tabsRouter) {
    // New lands on the Activity tab — NewThreadRoute lives there. The inner
    // stack must end up as [PriorityOnlyRoute, NewThreadRoute] so that back
    // from /new pops to the priority page (not an empty navigator).
    //
    // Reset vs resume vs fresh depends on where we already are:
    //
    // - An in-progress /new is parked on the Activity stack while a DIFFERENT
    //   tab is showing → just switch to the Activity tab to RESUME the draft
    //   (no reset — the design preserves a draft across tab switches).
    // - We're ALREADY viewing /new (Activity tab active) and the user taps New
    //   again → reset to step 1 with a fresh draft (tap-active = start over).
    // - No /new on the stack (we're on the feed or a thread) → push a FRESH
    //   NewThreadRoute and reset so the new mount starts clean.
    //
    // AutoRoute reuses an already-mounted NewThreadPage (it does not build a
    // new State), so a live page sitting on step 2 would otherwise reappear
    // mid-compose; requestReset() resets it to step 1 with a fresh draft, and a
    // fresh mount ignores the bump.
    //
    // Avoid `navigate(PriorityRoute(children:[New]))` (drops the inner child if
    // PriorityRoute is already on the Activity stack) and
    // `navigatePath('/p/:pid/new')` (sets the inner stack to [NewThreadRoute]
    // only, with nothing to pop back to).
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      final onNewThread = innerRouter.current.name == NewThreadRoute.name;
      if (onNewThread) {
        if (tabsRouter.activeIndex == _kTabActivity) {
          // Already viewing /new → tap-active starts over at step 1.
          NewThreadPageState.requestReset();
        } else {
          // /new parked while another tab is active → resume the draft.
          tabsRouter.setActiveIndex(_kTabActivity);
        }
        return;
      }
      // No /new on the stack — fresh compose: reset then push.
      NewThreadPageState.requestReset();
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      innerRouter.push(NewThreadRoute());
      return;
    }

    // Cold-start path: PriorityRoute isn't mounted yet (first activation from
    // Agenda/Priorities). Navigate to PriorityRoute (which seeds the inner
    // stack with the empty-path PriorityOnlyRoute) and push NewThreadRoute on
    // top once the inner router appears. A fresh mount, so reset to be safe.
    NewThreadPageState.requestReset();

    final priorityIdString = _activityPriorityIdString(context);
    if (priorityIdString == null) return;
    // Signal the intent so UnifiedHeader collapses immediately rather
    // than flashing the full priority header while PriorityWrapper is
    // mounting and we're polling for the inner router to appear.
    // Cleared by NewThreadPage on mount; this timeout is a safety net
    // in case the polling ever fails to land us on /new (e.g. the
    // priority load future never resolves) so the collapsed header
    // doesn't persist forever.
    ThreadHeaderNotifier.pendingNewThreadIntent.value = true;
    Future.delayed(const Duration(seconds: 3), () {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    });
    context.router.navigate(
      PriorityRoute(priorityIdString: priorityIdString),
    );
    _pushNewThreadWhenInnerReady(context, attempt: 0);
  }

  /// PriorityWrapper hosts the inner AutoRouter, but doesn't build it
  /// until PriorityBlocProvider's priority-load future resolves (a DB
  /// read that takes 200ms+ on cold start). Poll across frames until
  /// the inner router becomes discoverable, then push NewThreadRoute.
  /// The 120-frame budget (~2s at 60Hz) covers slow disks while still
  /// bailing out if something goes wrong.
  static void _pushNewThreadWhenInnerReady(
    BuildContext context, {
    required int attempt,
    bool? feedback,
    String? notePriorityId,
  }) {
    if (!context.mounted) return;
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(
          NewThreadRoute(feedback: feedback, notePriorityId: notePriorityId),
        );
      }
      return;
    }
    if (attempt >= 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushNewThreadWhenInnerReady(
        context,
        attempt: attempt + 1,
        feedback: feedback,
        notePriorityId: notePriorityId,
      );
    });
  }

  /// Opens the new-thread compose flow in **Help & Feedback** mode (a Plot-Team
  /// chat filed under the user's Inbox), driving the Activity-tab inner stack
  /// directly so it works in BOTH single- and multi-panel.
  ///
  /// The [HelpAndFeedback] command used to return
  /// `CommandRoute(PriorityRoute(children: [NewThreadRoute(feedback: true)]))`,
  /// but `navigate` silently DROPS that inner child whenever PriorityRoute is
  /// already mounted (e.g. the user was viewing a thread when they opened
  /// settings), so the compose screen never appeared — the same trap
  /// documented on [_openNewThread] and in the onboarding overlay. This mirrors
  /// [_openNewThread]: reconfigure an already-live page via
  /// [NewThreadPageState.requestFeedback], otherwise push a fresh feedback
  /// compose onto the inner stack (polling for the inner router on cold start).
  ///
  /// [rootPriorityIdString] seeds the Activity-tab PriorityRoute on cold start;
  /// the page forces the Inbox focus itself once mounted (see
  /// `NewThreadPageState._applyFeedbackMode`).
  static void _openFeedbackThread(
    BuildContext context,
    String rootPriorityIdString,
  ) {
    // Prefer the always-mounted root navigator context so the cold-start poll
    // survives the settings modal / More-tab row that triggered this being
    // torn down. Falls back to the passed context if it isn't available yet.
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;

    // Reconfigure an already-live (AutoRoute-reused) new-thread page for
    // feedback; a fresh mount instead reacts to the `feedback` route param.
    NewThreadPageState.requestFeedback();

    final tabsRouter = _findTabsRouter(ctx.router.root);
    final innerRouter = _findPriorityInnerRouter(ctx.router.root);
    if (tabsRouter != null && innerRouter != null) {
      // Reveal the Activity tab (single-panel may be on More/Search; multi-
      // panel is already there).
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      // Not already composing → push a fresh feedback compose; otherwise the
      // requestFeedback() above reconfigures the live page in place.
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute(feedback: true));
      }
      return;
    }

    // Cold-start path: the Activity-tab PriorityRoute isn't mounted yet (e.g.
    // single-panel launch → More tab without ever visiting a focus). Mount the
    // Inbox PriorityRoute (which also activates the Activity tab) then push the
    // feedback compose once the inner router materializes.
    ThreadHeaderNotifier.pendingNewThreadIntent.value = true;
    Future.delayed(const Duration(seconds: 3), () {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    });
    ctx.router.navigate(PriorityRoute(priorityIdString: rootPriorityIdString));
    _pushNewThreadWhenInnerReady(ctx, attempt: 0, feedback: true);
  }

  /// Opens the new-thread compose flow in **private-note** mode for
  /// [priorityIdString] — the sidebar's per-focus "Add private note"
  /// shortcut. Mirrors [_openFeedbackThread]: reconfigure an already-live
  /// page via [NewThreadPageState.requestNote], otherwise push a fresh
  /// private-note compose onto the inner stack (polling for the inner
  /// router on cold start). Unlike feedback (always anchored to Inbox), the
  /// cold-start seed priority is the clicked focus itself.
  static void _openPrivateNote(
    BuildContext context,
    String priorityIdString,
  ) {
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;

    // Reconfigure an already-live (AutoRoute-reused) new-thread page for a
    // private note; a fresh mount instead reacts to the `notePriorityId`
    // route param.
    NewThreadPageState.requestNote(priorityIdString);

    final tabsRouter = _findTabsRouter(ctx.router.root);
    final innerRouter = _findPriorityInnerRouter(ctx.router.root);
    if (tabsRouter != null && innerRouter != null) {
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute(notePriorityId: priorityIdString));
      }
      return;
    }

    // Cold-start path: the Activity-tab PriorityRoute isn't mounted yet.
    // Mount it seeded with the clicked focus, then push the private-note
    // compose once the inner router materializes.
    ThreadHeaderNotifier.pendingNewThreadIntent.value = true;
    Future.delayed(const Duration(seconds: 3), () {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    });
    ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
    _pushNewThreadWhenInnerReady(
      ctx,
      attempt: 0,
      notePriorityId: priorityIdString,
    );
  }

  /// Static new-thread navigation for screenshot scene S5. Mirrors
  /// [_openFeedbackThread] but composes a normal (non-feedback) thread under
  /// [priorityIdString], driving the Activity-tab inner stack so it lands on
  /// the compose page in single- AND multi-panel.
  static void _openNewThreadStatic(
    BuildContext context,
    String priorityIdString,
  ) {
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;
    NewThreadPageState.requestReset();
    final tabsRouter = _findTabsRouter(ctx.router.root);
    final innerRouter = _findPriorityInnerRouter(ctx.router.root);
    if (tabsRouter != null && innerRouter != null) {
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute());
      }
      return;
    }
    ThreadHeaderNotifier.pendingNewThreadIntent.value = true;
    Future.delayed(const Duration(seconds: 3), () {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    });
    ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
    _pushNewThreadWhenInnerReady(ctx, attempt: 0);
  }

  /// Static focus-open navigation for the widget bridge. Activates the Activity
  /// tab and navigates to [PriorityRoute] for [priorityIdString]. Called via the
  /// context-free [PrioritiesShell.openFocus] entry point.
  static void _openFocusStatic(
    BuildContext context,
    String priorityIdString,
  ) {
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;
    final tabsRouter = _findTabsRouter(ctx.router.root);
    if (tabsRouter != null && tabsRouter.activeIndex != _kTabActivity) {
      tabsRouter.setActiveIndex(_kTabActivity);
    }
    ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
  }

  /// Static thread-open navigation for screenshot scenes S2/S7. Switches to the
  /// Activity tab, seeds the thread's focus, then pushes ThreadRoute onto the
  /// inner stack once it materializes — the same mechanism as a thread tap.
  static void _openThreadStatic(
    BuildContext context,
    String priorityIdString,
    String threadIdString,
  ) {
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;
    final tabsRouter = _findTabsRouter(ctx.router.root);
    if (tabsRouter != null && tabsRouter.activeIndex != _kTabActivity) {
      tabsRouter.setActiveIndex(_kTabActivity);
    }
    // Cold-start only: the focus's inner router isn't mounted yet — seed it.
    // When it IS mounted (warm), do NOT re-navigate the focus: that re-seeds
    // the inner default and clobbers the thread. In both cases the thread is
    // pushed by _pushThreadWhenInnerReady, which waits for the inner stack to
    // settle on its default child (PriorityOnlyRoute single / NewThreadRoute
    // multi) before pushing ON TOP — so it survives the seeding. ThreadRoute
    // resolves by id regardless of which focus is showing.
    if (_findPriorityInnerRouter(ctx.router.root) == null) {
      ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
    }
    _pushThreadWhenInnerReady(ctx, threadIdString, attempt: 0);
  }

  static void _pushThreadWhenInnerReady(
    BuildContext context,
    String threadIdString, {
    required int attempt,
  }) {
    if (!context.mounted) return;
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      final current = innerRouter.current.name;
      if (current == ThreadRoute.name) return; // already there
      // Wait until the inner stack has settled on its FINAL default child
      // before pushing, so the thread lands ON TOP and isn't clobbered by the
      // default-child seeding. Multi-panel (iPad/desktop) seeds PriorityOnlyRoute
      // transiently and then NewThreadRoute — pushing on the transient
      // PriorityOnlyRoute gets stomped 2ms later by the NewThreadRoute seed, so
      // wait for the platform's settled default: NewThreadRoute multi-panel,
      // PriorityOnlyRoute single-panel.
      final multi = LayoutBloc.instance?.state.multiPanel ?? false;
      final settledDefault =
          multi ? NewThreadRoute.name : PriorityOnlyRoute.name;
      if (current == settledDefault) {
        innerRouter.push(ThreadRoute(threadIdString: threadIdString));
        return;
      }
    }
    if (attempt >= 120) {
      if (innerRouter != null) {
        innerRouter.push(ThreadRoute(threadIdString: threadIdString));
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushThreadWhenInnerReady(context, threadIdString, attempt: attempt + 1);
    });
  }

  /// Walks the controller tree to find the [StackRouter] hosted by the
  /// active [PriorityRoute]. [innerRouterOf] is non-recursive, so a deeply
  /// nested route like PriorityRoute (root → AppShell → tabs → ActivityShell
  /// → PriorityRoute) needs an explicit walk.
  static StackRouter? _findPriorityInnerRouter(RoutingController root) {
    final direct =
        root.innerRouterOf<StackRouter>(PriorityRoute.name);
    if (direct != null) return direct;
    for (final child in root.childControllers) {
      final hit = _findPriorityInnerRouter(child);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Walks the controller tree to find the root [TabsRouter] (the
  /// [AutoTabsRouter] hosted in [build]). Mirrors [_findPriorityInnerRouter] so
  /// the static [openFeedbackThread] entry point can switch tabs without an
  /// [AutoTabsRouter.of] lookup (the command may run from a modal outside the
  /// tabs subtree).
  static TabsRouter? _findTabsRouter(RoutingController root) {
    if (root is TabsRouter) return root;
    for (final child in root.childControllers) {
      final hit = _findTabsRouter(child);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AutoTabsRouter(
      // The app lands on Threads (the Priorities tab) by default. Agenda
      // stays reachable via its own bottom-nav slot when a calendar
      // connection exists, but it's no longer the home tab.
      homeIndex: _kTabPriorities,
      routes: [
        PrioritiesRoute(),
        EmptyShellRoute("AgendaShell")(),
        EmptyShellRoute("ActivityShell")(),
        EmptyShellRoute("SearchShell")(),
        EmptyShellRoute("MoreShell")(),
      ],
      transitionBuilder: (context, child, animation) => child,
      builder: (context, child) {
        final tabsRouter = AutoTabsRouter.of(context);
        return BlocBuilder<LayoutBloc, LayoutState>(
          buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
          builder: (context, layoutState) {
            // Multi-panel (desktop / wide layouts) doesn't show the
            // bottom nav at all and uses tab 2 (the Activity stack) as
            // the working area. Keep the existing behavior of forcing
            // the active tab to Activity in multi-panel mode.
            if (layoutState.multiPanel) {
              if (tabsRouter.activeIndex != _kTabActivity) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  // On a single-panel cold start RootPage lands on the
                  // Priorities tab (tab 0) and never seeds the Activity
                  // tab (tab 2) — the stack where PriorityRoute/threads
                  // live. Force-switching to an empty Activity stack
                  // renders a blank navigator (the multi-panel working
                  // area has nothing in it). If it's empty, seed it with
                  // the current priority first; navigate() both pushes
                  // PriorityRoute and activates the Activity tab. This
                  // mirrors RootPage's multi-panel branch, which only
                  // runs when the app cold-starts wide.
                  final activityStack =
                      tabsRouter.stackRouterOfIndex(_kTabActivity);
                  if (activityStack == null || activityStack.stack.isEmpty) {
                    final priorityIdString =
                        _activityPriorityIdString(context);
                    if (priorityIdString != null) {
                      context.router.navigate(
                        PriorityRoute(priorityIdString: priorityIdString),
                      );
                      return;
                    }
                  }
                  tabsRouter.setActiveIndex(_kTabActivity);
                });
              }
              return child;
            }

            return StreamBuilder<bool>(
              stream: TwistInstance.watchHasCalendarConnection(),
              initialData: TwistInstance.hasCalendarConnectionInCache,
              builder: (context, snap) {
                final hasCalendar = snap.data ?? false;
                final slots = navSlotsFor(hasCalendar: hasCalendar);

                // Guard: if the agenda is hidden but the user is on the
                // agenda tab (e.g. removed their last calendar connection
                // while viewing it), bounce to Focuses. Mirrors the
                // multi-panel force-to-Activity pattern above.
                if (!hasCalendar && tabsRouter.activeIndex == _kTabAgenda) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    if (tabsRouter.activeIndex == _kTabAgenda) {
                      tabsRouter.setActiveIndex(_kTabPriorities);
                    }
                  });
                }

                final hideNav = _isFullScreenRoute(context);
                final navIndex = _currentNavIndex(context, tabsRouter, slots);
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
          },
        );
      },
    );
  }

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
              // The FYI is an ordinary focus for the unread indicator — its
              // unread contributes to the global Focus-tab dot like any focus.
              // (Notifications stay disabled for FYI; that is handled
              // separately by the push/badge paths, not this in-app dot.)
              final hasUnread = state.priorities.any(
                (p) => p.unread || p.descendants().any((d) => d.unread),
              );

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(PlotIcon.focusDefault),
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
          label: _buildNavLabel('Focus'),
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
          // Only an *active* connection (one with an enabled channel) needing
          // re-auth lights the badge — a dormant connection is hidden from the
          // connections list, so flagging it would nag with no row to act on.
          // See [TwistConnection.anyActiveNeedsReauth].
          icon: StreamBuilder<bool>(
            stream: TwistConnection.watchActiveNeedsReauth(),
            initialData: false,
            builder: (context, snap) {
              if (snap.data ?? false) {
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
}

/// Renders the active tab content with a persistent bottom nav overlaid
/// on top via a [Stack].
///
/// Earlier iterations used `Column(Expanded(child), AnimatedSize(nav))`,
/// but resizing the body whenever the nav showed or hid disrupted any
/// in-flight page transition inside the body's [AutoRouter] — pushes and
/// pops swapped content instantly because the transitioning Navigator's
/// bounds were changing under it. Using a Stack keeps the body's bounds
/// constant; the nav slides in/out via translation without affecting the
/// content area.
class _MobileShellChrome extends StatefulWidget {
  const _MobileShellChrome({
    required this.child,
    required this.showNav,
    required this.currentIndex,
    required this.onChange,
    required this.items,
  });

  final Widget child;
  final bool showNav;
  final int currentIndex;
  final ValueChanged<int> onChange;
  final List<FBottomNavigationBarItem> items;

  @override
  State<_MobileShellChrome> createState() => _MobileShellChromeState();
}

class _MobileShellChromeState extends State<_MobileShellChrome> {
  // Suppress the slide animation on the very first paint so the nav
  // doesn't visibly slide up when the app cold-starts. Without this,
  // the chrome briefly mounts with showNav transitioning false → true
  // (initial route resolution) and AnimatedSlide animates from
  // off-screen into place even though there's no real navigation.
  bool _firstBuild = true;

  // Measured height of the bottom nav (background + items + safe-area
  // inset). Published through [BottomNavInset] so pages that pin
  // content to the bottom — e.g. the single-panel activity-feed tab
  // bar — can offset themselves to sit just above the nav instead of
  // being painted under it.
  final GlobalKey _navKey = GlobalKey();
  double _navHeight = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_firstBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _firstBuild = false);
      });
    }
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _navKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final height = renderObject.size.height;
      if (height != _navHeight) {
        setState(() => _navHeight = height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final reservedHeight = widget.showNav ? _navHeight : 0.0;
    return Stack(
      children: [
        Positioned.fill(
          child: BottomNavInset(
            height: reservedHeight,
            child: widget.child,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: widget.showNav ? Offset.zero : const Offset(0, 1),
            duration: _firstBuild
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !widget.showNav,
              child: _PersistentBottomNav(
                key: _navKey,
                currentIndex: widget.currentIndex,
                onChange: widget.onChange,
                items: widget.items,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Publishes the measured height of the overlaid bottom-nav so pages
/// can pin content (e.g. the single-panel activity-feed tab bar) just
/// above it. Returns 0 in multi-panel and on routes that hide the nav.
class BottomNavInset extends InheritedWidget {
  const BottomNavInset({required this.height, required super.child, super.key});

  final double height;

  static double of(BuildContext context) {
    final inset =
        context.dependOnInheritedWidgetOfExactType<BottomNavInset>();
    return inset?.height ?? 0;
  }

  @override
  bool updateShouldNotify(BottomNavInset oldWidget) =>
      height != oldWidget.height;
}

/// Wraps a *secondary* bottom-nav tab root (Agenda / More) with a back-gesture
/// handler so Android's predictive back returns to the previously active tab
/// (via [returnFromSecondaryTab]) instead of falling through the nested
/// navigators and exiting the app.
///
/// Single-panel only: multi-panel hides the bottom nav and forces the Activity
/// tab, so these tab roots are never the active back target there — the
/// [PopScope] would otherwise needlessly intercept a desktop back. The Search
/// tab does NOT use this wrapper; it has its own inline [PopScope] that first
/// clears a typed query before leaving the tab.
class SecondaryTabBackScope extends StatelessWidget {
  const SecondaryTabBackScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        if (layoutState.multiPanel) return child;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            returnFromSecondaryTab(context);
          },
          child: child,
        );
      },
    );
  }
}

/// Wraps the **Focus home** bottom-nav tab (tab 0) so the Android back gesture
/// *exits the app* from there instead of no-op'ing with a haptic. The Focus
/// home is the back target every other tab and the priority feed funnel into
/// ([returnFromSecondaryTab] / [returnFromPriorityToSourceTab]), so it's the
/// terminal "one more back exits" step — but on its own it had nothing wired
/// to actually exit.
///
/// Why an explicit [SystemNavigator.pop] is needed rather than relying on the
/// platform default: the bottom-nav tabs live in an [AutoTabsRouter]
/// [IndexedStack] that keeps every visited tab mounted. The Activity/Search/
/// secondary tabs each mount a `PopScope(canPop: false)`, and Flutter reports
/// `SystemNavigator.setFrameworkHandlesBack(true)` whenever *any* mounted route
/// blocks pop — including an offstage IndexedStack tab. So once the user has
/// opened a focus feed, the framework permanently claims to handle back; on the
/// Focus home tab (a leaf route with nothing to pop) the system back is then
/// swallowed into a no-op haptic instead of backgrounding the app. Handling the
/// pop here and calling [SystemNavigator.pop] makes the exit deterministic
/// regardless of that stale state.
///
/// Tab 0 ([PriorityTabs.priorities] / `PrioritiesRoute`) is a leaf — drilling
/// into a focus navigates to the Activity tab, never within this tab's own
/// navigator — so when this scope's [PopScope] fires there is never an inner
/// route to pop first; exiting is always the correct action.
///
/// Single-panel only: multi-panel (desktop) hides the bottom nav and has no
/// Android back gesture, so it must pass through untouched. Mirrors
/// [SecondaryTabBackScope].
class FocusHomeBackScope extends StatelessWidget {
  const FocusHomeBackScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        if (layoutState.multiPanel) return child;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            // Top of the home stack — nothing left to navigate back to, so
            // background the app like the native root back gesture would.
            SystemNavigator.pop();
          },
          child: child,
        );
      },
    );
  }
}

class _PersistentBottomNav extends StatelessWidget {
  const _PersistentBottomNav({
    required this.currentIndex,
    required this.onChange,
    required this.items,
    super.key,
  });

  /// Visual index of the highlighted item, or -1 when no item should be
  /// highlighted (e.g. while viewing a priority's activity list, which
  /// no longer has a dedicated bottom-nav slot). FBottomNavigationBar
  /// supports -1 natively — it just renders every item unselected.
  final int currentIndex;
  final ValueChanged<int> onChange;
  final List<FBottomNavigationBarItem> items;

  @override
  Widget build(BuildContext context) {
    // Border color from the OUTER (un-darkened) theme — the bar darkens its
    // own theme by 2 steps, so reading `border` inside that FTheme yields a
    // near-black line on the near-black bar (invisible). The outer border is
    // the same visible separator the agenda divider uses.
    final borderColor = context.theme.colors.border;
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => DecoratedBox(
          decoration: BoxDecoration(color: context.theme.colors.background),
          // Draw the top hairline as a sibling ABOVE the bar, not as a
          // BoxDecoration border: a background-position border paints behind
          // the opaque FBottomNavigationBar and is hidden. A first-child
          // Container is painted on top and is visible (same approach as the
          // agenda's mobile top divider).
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(height: 1, color: borderColor),
              SafeArea(
                top: false,
                left: false,
                right: false,
                child: FBottomNavigationBar(
                  index: currentIndex,
                  onChange: onChange,
                  children: items,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
