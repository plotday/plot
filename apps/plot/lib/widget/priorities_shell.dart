import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:collection/collection.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/widget/icon.dart';

/// Visual indices used by the bottom nav.
const int _kTabPriorities = 0;
const int _kTabAgenda = 1;
const int _kTabActivity = 2;
const int _kBtnNew = 3;
const int _kBtnMore = 4;

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget {
  const PrioritiesShell({super.key});

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

  /// Maps the active tab + URL to the visual nav index. The Priorities,
  /// Agenda, and Activity tabs each map directly to their bottom-nav
  /// indices; "New" lights up while the user is on `…/new`; thread pages
  /// hide the nav so they have no highlighted index.
  int _currentNavIndex(BuildContext context, TabsRouter tabsRouter) {
    final currentPath = context.router.currentPath;
    if (currentPath.endsWith('/new')) return _kBtnNew;
    final pathSegments =
        currentPath.split('/').where((s) => s.isNotEmpty).toList();
    if (pathSegments.length >= 3 ||
        (pathSegments.isNotEmpty && pathSegments.first == 't')) {
      return -1;
    }
    return tabsRouter.activeIndex;
  }

  void _handleNavTap(
    BuildContext context,
    TabsRouter tabsRouter,
    int index,
  ) {
    switch (index) {
      case _kTabPriorities:
        tabsRouter.setActiveIndex(_kTabPriorities);
        return;
      case _kTabAgenda:
        tabsRouter.setActiveIndex(_kTabAgenda);
        return;
      case _kTabActivity:
        _activateActivityTab(context, tabsRouter);
        return;
      case _kBtnNew:
        _openNewThread(context, tabsRouter);
        return;
      case _kBtnMore:
        ShowSettings().run(context);
        return;
    }
  }

  /// Switch to the Activity tab. If the tab has no route on its stack
  /// yet (first activation), push the user's current/default priority.
  /// If we're already on the Activity tab inside a thread, pop back to
  /// the priority root instead of staying on the thread.
  void _activateActivityTab(BuildContext context, TabsRouter tabsRouter) {
    final activityRouter = tabsRouter.stackRouterOfIndex(_kTabActivity);
    final alreadyOnTab = tabsRouter.activeIndex == _kTabActivity;

    if (alreadyOnTab && activityRouter != null) {
      // On the Activity tab — drop back to the priority root if we drilled
      // deeper (e.g. into a thread or new-thread page). Repeated taps on
      // the Activity tab while at the root are no-ops.
      while (activityRouter.canPop()) {
        activityRouter.maybePop();
      }
      return;
    }

    // First activation of the tab (or switching back to it from another
    // tab). If the tab already holds a stack, just activate it; else
    // push the user's current/default priority.
    if (activityRouter != null && activityRouter.stack.isNotEmpty) {
      tabsRouter.setActiveIndex(_kTabActivity);
      return;
    }
    final priorityIdString = _activityPriorityIdString(context);
    if (priorityIdString == null) return;
    context.router.navigate(
      PriorityRoute(priorityIdString: priorityIdString),
    );
  }

  void _openNewThread(BuildContext context, TabsRouter tabsRouter) {
    // Always lands on the Activity tab — NewThreadRoute lives there.
    //
    // If a PriorityRoute is already mounted (we're on it now, or it's
    // alive on the Activity tab's stack while another tab is active),
    // push NewThreadRoute onto its inner stack so the back gesture
    // returns to that priority. `root.navigate(PriorityRoute(children:[New]))`
    // only activates the existing PriorityRoute and leaves its inner
    // stack on the default PriorityOnlyRoute — producing the "opens
    // Activity, not New" bug when triggered from Agenda or Priorities.
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

    // PriorityWrapper isn't mounted yet (first activation of Activity
    // tab on a cold start from Agenda/Priorities). Use path-based
    // navigation: `navigatePath` resolves the full path match including
    // the `/new` segment, which seeds the inner stack correctly once
    // PriorityWrapper's async loading (priority DB read) settles. The
    // `children: [NewThreadRoute()]` form of `navigate()` drops the
    // inner child in this case.
    final priorityIdString = _activityPriorityIdString(context);
    if (priorityIdString == null) return;
    context.router.root.navigatePath('/p/$priorityIdString/new');
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
      homeIndex: _kTabAgenda,
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

            final hideNav = _isFullScreenRoute(context);
            final navIndex = _currentNavIndex(context, tabsRouter);
            return _MobileShellChrome(
              showNav: !hideNav,
              currentIndex: navIndex,
              onChange: (i) => _handleNavTap(context, tabsRouter, i),
              items: _buildNavItems(context),
              child: child,
            );
          },
        );
      },
    );
  }

  List<FBottomNavigationBarItem> _buildNavItems(BuildContext context) {
    return [
      FBottomNavigationBarItem(
        icon: Icon(PlotIcon.priorities),
        label: _buildNavLabel('Priorities'),
      ),
      FBottomNavigationBarItem(
        icon: Icon(PlotIcon.agenda),
        label: _buildNavLabel('Agenda'),
      ),
      FBottomNavigationBarItem(
        icon: BlocBuilder<PrioritiesBloc, PrioritiesState>(
          builder: (context, state) {
            final pathSegments = context.router.currentPath
                .split('/')
                .where((s) => s.isNotEmpty)
                .toList();
            final priorityIdString =
                pathSegments.isNotEmpty ? pathSegments[0] : null;
            final priority = priorityIdString != null
                ? state.priorities.firstWhereOrNull(
                    (p) => p.id.toShortString() == priorityIdString,
                  )
                : null;
            final hasUnread = priority != null &&
                (priority.unread ||
                    priority.descendants().any((p) => p.unread));

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(PlotIcon.activity),
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
        label: _buildNavLabel('Activity'),
      ),
      FBottomNavigationBarItem(
        icon: Icon(PlotIcon.addNote),
        label: _buildNavLabel('New'),
      ),
      FBottomNavigationBarItem(
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
      ),
    ];
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
class _MobileShellChrome extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: showNav ? Offset.zero : const Offset(0, 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !showNav,
              child: _PersistentBottomNav(
                currentIndex: currentIndex < 0 ? 0 : currentIndex,
                onChange: onChange,
                items: items,
                highlight: currentIndex >= 0,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PersistentBottomNav extends StatelessWidget {
  const _PersistentBottomNav({
    required this.currentIndex,
    required this.onChange,
    required this.items,
    required this.highlight,
  });

  final int currentIndex;
  final ValueChanged<int> onChange;
  final List<FBottomNavigationBarItem> items;
  final bool highlight;

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
            // When the current route doesn't correspond to any tab (e.g.
            // a thread) we render the nav with no highlighted item by
            // hiding the selection ring via opacity tricks. In practice
            // we only render when [highlight] is true since
            // [_MobileShellChrome] hides the nav on those routes; the
            // flag is kept for completeness.
            child: Opacity(
              opacity: highlight ? 1.0 : 0.0,
              child: FBottomNavigationBar(
                index: currentIndex,
                onChange: onChange,
                children: items,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
