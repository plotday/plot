import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/new_thread.dart' show NewThreadPageState;
import 'package:plot/store/store.dart';
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

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();
}

class _PrioritiesShellState extends State<PrioritiesShell> {
  Listenable? _navHistory;

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
    if (currentPath.endsWith('/new')) return true;
    final pathSegments =
        currentPath.split('/').where((s) => s.isNotEmpty).toList();
    return pathSegments.length >= 3 ||
        (pathSegments.isNotEmpty && pathSegments.first == 't');
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
      default:
        // Activity tab (or anything else) — no bottom-nav highlight.
        return -1;
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
    // Navigating away from the current page should leave search closed —
    // otherwise coming back via Search would toggle the stale state closed
    // instead of opening it fresh. More just opens a modal, so it leaves
    // search alone.
    if (slot != NavSlot.search && slot != NavSlot.more) {
      LayoutBloc.instance?.requestSearchClose();
    }
    switch (slot) {
      case NavSlot.focuses:
        // Bottom nav is "replace" — back from /priorities should exit
        // the app, not return to whatever cross-tab origin was tracked.
        // [markUrlStateForReplace] is consumed by the next URL state
        // emission (triggered by setActiveIndex → notifyAll →
        // rebuildUrl) so the URL-history entry replaces the previous
        // one instead of pushing. That keeps browser back / Cmd+[
        // walking only the meaningful navigation steps.
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

  /// Bottom-nav Search button. Search lives on a [PriorityRoute] — so
  /// when the user is on the Priorities or Agenda tab (or any non-priority
  /// route) we first switch to the Activity tab, navigating to the user's
  /// default/root priority if its stack is empty. If we're already on a
  /// priority page, the existing header just expands its search inline.
  ///
  /// Single-panel search runs across the Everything feed, so switch to it
  /// up front — before any query is typed — so the results span every
  /// thread. This method only runs from the single-panel bottom nav. In
  /// multi-panel the priorities sidebar swaps to the global-view
  /// focus-as-filter panel whenever a query or filter is active; results are
  /// global regardless of the selected focus (driven by
  /// `PriorityBloc.globalViewScope`), so no context switch or restore is
  /// needed there.
  void _openSearch(BuildContext context, TabsRouter tabsRouter) {
    final layoutBloc = LayoutBloc.instance;
    final onActivityTab = tabsRouter.activeIndex == _kTabActivity;

    final nowBloc = context.read<NowBloc>();
    final nowState = nowBloc.state;
    if (nowState is NowLoaded && !nowState.everything) {
      nowBloc.setContext(nowState.defaultPriority, everything: true);
    }

    if (onActivityTab &&
        layoutBloc != null &&
        layoutBloc.hasSearchToggle) {
      layoutBloc.requestSearchToggle();
      return;
    }

    final activityRouter = tabsRouter.stackRouterOfIndex(_kTabActivity);
    if (activityRouter != null && activityRouter.stack.isNotEmpty) {
      // Activity tab already has a priority page on its stack — just
      // surface it and let its header pick up the toggle request.
      tabsRouter.setActiveIndex(_kTabActivity);
      _expandSearchWhenReady(context, attempt: 0);
      return;
    }

    final priorityIdString = _activityPriorityIdString(context);
    if (priorityIdString == null) return;
    context.router.navigate(
      PriorityRoute(priorityIdString: priorityIdString),
    );
    _expandSearchWhenReady(context, attempt: 0);
  }

  /// Polls across frames until a unified_header registers its toggle
  /// handler with [LayoutBloc] (which happens in its first
  /// didChangeDependencies). Mirrors [_pushNewThreadWhenInnerReady]'s
  /// frame budget for parity with the New-thread cold-start path.
  void _expandSearchWhenReady(BuildContext context, {required int attempt}) {
    if (!context.mounted) return;
    final layoutBloc = LayoutBloc.instance;
    if (layoutBloc != null && layoutBloc.hasSearchToggle) {
      layoutBloc.requestSearchToggle();
      return;
    }
    if (attempt >= 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _expandSearchWhenReady(context, attempt: attempt + 1);
    });
  }

  void _openNewThread(BuildContext context, TabsRouter tabsRouter) {
    // Always start a fresh new-thread flow. AutoRoute reuses an already-mounted
    // NewThreadPage (it does not build a new State), so a page sitting on
    // step 2 would otherwise reappear mid-compose. A live page resets to
    // step 1 with a fresh draft; a fresh mount ignores this bump.
    NewThreadPageState.requestReset();

    // Always lands on the Activity tab — NewThreadRoute lives there.
    //
    // The inner stack must end up as [PriorityOnlyRoute, NewThreadRoute]
    // so that back from /new pops to the priority page (not an empty
    // navigator). Two paths get us there:
    //
    // 1. PriorityRoute is already mounted (we're on it now, or it's
    //    alive on the Activity stack while another tab is active) →
    //    push NewThreadRoute on the existing inner router.
    // 2. PriorityRoute isn't mounted yet (first cold-start activation
    //    from Agenda/Priorities) → navigate to PriorityRoute (which
    //    seeds the inner stack with the empty-path PriorityOnlyRoute)
    //    and push NewThreadRoute on top once the inner router appears.
    //
    // Avoid `navigate(PriorityRoute(children:[New]))` (drops the inner
    // child if PriorityRoute is already on the Activity stack) and
    // `navigatePath('/p/:pid/new')` (sets the inner stack to
    // [NewThreadRoute] only, with nothing to pop back to).
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute());
      }
      return;
    }

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
  void _pushNewThreadWhenInnerReady(
    BuildContext context, {
    required int attempt,
  }) {
    if (!context.mounted) return;
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute());
      }
      return;
    }
    if (attempt >= 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushNewThreadWhenInnerReady(context, attempt: attempt + 1);
    });
  }

  /// Walks the controller tree to find the [StackRouter] hosted by the
  /// active [PriorityRoute]. [innerRouterOf] is non-recursive, so a deeply
  /// nested route like PriorityRoute (root → AppShell → tabs → ActivityShell
  /// → PriorityRoute) needs an explicit walk.
  StackRouter? _findPriorityInnerRouter(RoutingController root) {
    final direct =
        root.innerRouterOf<StackRouter>(PriorityRoute.name);
    if (direct != null) return direct;
    for (final child in root.childControllers) {
      final hit = _findPriorityInnerRouter(child);
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
          label: _buildNavLabel('Threads'),
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
    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => DecoratedBox(
          decoration: BoxDecoration(
            color: context.theme.colors.background,
          ),
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            child: FBottomNavigationBar(
              index: currentIndex,
              onChange: onChange,
              children: items,
            ),
          ),
        ),
      ),
    );
  }
}
