import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/router.dart';
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
      case _kTabSearch:
        return slots.indexOf(NavSlot.search);
      case _kTabMore:
        return slots.indexOf(NavSlot.more);
      default:
        // Activity tab — no highlight unless on /new (handled above).
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
        // New stays on the Activity stack (a later task owns reset/post-send).
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
