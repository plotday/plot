import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:collection/collection.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/bottom_navigation_provider.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/page/priority.dart';

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget {
  const PrioritiesShell({super.key});

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();
}

class _PrioritiesShellState extends State<PrioritiesShell> with AutoRouteAware {
  AutoRouteObserver? _observer;
  final PriorityTabNotifier _tabNotifier = PriorityTabNotifier();

  @override
  void initState() {
    super.initState();
    _tabNotifier.addListener(_onTabChanged);
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

  void _onTabChanged() {
    // Defer setState — the notifier may fire during a build frame
    // (e.g. when PriorityPage.didChangeDependencies forces the viewer tab).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route changes to rebuild bottom nav when navigating to/from NewThreadPage
    _observer = RouterScope.of(
      context,
    ).firstObserverOfType<AutoRouteObserver>();
    _observer?.subscribe(this, context.router.current);
  }

  @override
  void dispose() {
    _observer?.unsubscribe(this);
    _tabNotifier.removeListener(_onTabChanged);
    _tabNotifier.dispose();
    super.dispose();
  }

  @override
  void didPush() {
    // Rebuild when route is pushed
    setState(() {});
  }

  @override
  void didPop() {
    // Rebuild when route is popped
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutStateProvider(
      child: PriorityTabProvider(
        notifier: _tabNotifier,
        child: AutoTabsRouter(
          homeIndex: 1,
          routes: [PrioritiesRoute(), EmptyShellRoute("PriorityShell")()],
          transitionBuilder: (context, child, animation) => child,
          builder: (context, child) {
            final tabsRouter = AutoTabsRouter.of(context);
            return BlocConsumer<LayoutBloc, LayoutState>(
              listenWhen: (previous, current) =>
                  previous.multiPanel != current.multiPanel,
              listener: (context, layoutState) {
                if (layoutState.multiPanel) {
                  tabsRouter.setActiveIndex(1);
                }
              },
              buildWhen: (previous, current) =>
                  previous.multiPanel != current.multiPanel,
              builder: (context, layoutState) {
                // Determine the correct tab index based on current route
                int getCurrentIndex() {
                  final currentPath = context.router.currentPath;
                  // If on NewThreadPage (/p/:priorityId/new), highlight New tab (index 3)
                  if (currentPath.endsWith('/new')) {
                    return 3;
                  }
                  // If on ThreadPage (/p/:priorityId/threadId), no tab highlighted
                  final pathSegments = currentPath
                      .split('/')
                      .where((s) => s.isNotEmpty)
                      .toList();
                  if (pathSegments.length >= 3 ||
                      (pathSegments.isNotEmpty && pathSegments.first == 't')) {
                    return -1;
                  }
                  // On the Threads tab, highlight Agenda or Activity Feed based on tab notifier
                  if (tabsRouter.activeIndex == 1) {
                    return _tabNotifier.value == PriorityTab.agenda ? 1 : 2;
                  }
                  // Otherwise use the tab router's active index
                  return tabsRouter.activeIndex;
                }

                // Hide bottom nav on full-screen routes (thread detail, new thread)
                bool isFullScreenRoute() {
                  final currentPath = context.router.currentPath;
                  if (currentPath.endsWith('/new')) return true;
                  final pathSegments = currentPath
                      .split('/')
                      .where((s) => s.isNotEmpty)
                      .toList();
                  return pathSegments.length >= 3 ||
                      (pathSegments.isNotEmpty && pathSegments.first == 't');
                }

                return BottomNavigationScope(
                  config: layoutState.multiPanel || isFullScreenRoute()
                      ? null
                      : BottomNavigationConfig(
                          currentIndex: getCurrentIndex(),
                          onChange: (index) {
                            final currentPath = context.router.currentPath;

                            if (index == 1 || index == 2) {
                              // Agenda (1) or Activity Feed (2) — switch to tab 1 and set tab notifier
                              final tab = index == 1
                                  ? PriorityTab.agenda
                                  : PriorityTab.activityFeed;
                              _tabNotifier.value = tab;

                              if (currentPath.endsWith('/new')) {
                                // On NewThreadPage - pop back
                                context.router.back();
                              } else {
                                final pathSegments = currentPath
                                    .split('/')
                                    .where((s) => s.isNotEmpty)
                                    .toList();
                                if ((pathSegments.length >= 3 ||
                                        (pathSegments.isNotEmpty &&
                                            pathSegments.first == 't')) &&
                                    tabsRouter.activeIndex == 1) {
                                  // On ThreadPage - pop back to PriorityPage
                                  context.router.back();
                                } else {
                                  tabsRouter.setActiveIndex(1);
                                }
                              }
                              setState(() {});
                            } else if (index == 3) {
                              // Navigate to New Thread for current priority
                              final pathSegments = currentPath
                                  .split('/')
                                  .where((s) => s.isNotEmpty)
                                  .toList();

                              // Check if we're on the Priorities tab
                              if (pathSegments.isNotEmpty &&
                                  pathSegments.first == 'priorities') {
                                // On Priorities tab - navigate to the Activities tab's current priority
                                final activitiesRouter = tabsRouter
                                    .stackRouterOfIndex(1);

                                // Switch tabs and navigate in a single frame to avoid flash
                                tabsRouter.setActiveIndex(1);
                                final innerRouter = activitiesRouter
                                    ?.innerRouterOf<StackRouter>(
                                      PriorityRoute.name,
                                    );

                                if (innerRouter != null) {
                                  // Navigate immediately without waiting for frame
                                  innerRouter.push(NewThreadRoute());
                                } else {
                                  // Fallback: wait one frame if inner router not ready
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    final innerRouter2 = tabsRouter
                                        .stackRouterOfIndex(1)
                                        ?.innerRouterOf<StackRouter>(
                                          PriorityRoute.name,
                                        );
                                    if (innerRouter2 != null) {
                                      innerRouter2.push(NewThreadRoute());
                                    }
                                  });
                                }
                              } else if (pathSegments.isNotEmpty &&
                                  pathSegments.first == 'p') {
                                // Already on a priority route - push NewThreadRoute directly
                                final innerRouter = context.router
                                    .innerRouterOf<StackRouter>(
                                      PriorityRoute.name,
                                    );
                                if (innerRouter != null) {
                                  innerRouter.push(NewThreadRoute());
                                } else {
                                  // Fallback: navigate with full route
                                  final priorityIdString = pathSegments[1];
                                  context.router.push(
                                    PriorityRoute(
                                      priorityIdString: priorityIdString,
                                      children: [NewThreadRoute()],
                                    ),
                                  );
                                }
                              }
                            } else if (index == 4) {
                              // Open settings modal
                              ShowSettings().run(context);
                            } else {
                              // Index 0: Priorities tab
                              if (currentPath.endsWith('/new')) {
                                // On NewThreadPage - pop first then switch tabs
                                context.router.back();
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  tabsRouter.setActiveIndex(index);
                                });
                              } else {
                                // Normal tab switching
                                tabsRouter.setActiveIndex(index);
                              }
                            }
                          },
                          items: [
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
                              icon: Icon(PlotIcon.menu),
                              label: _buildNavLabel('More'),
                            ),
                          ],
                        ),
                  child: child,
                );
              },
            );
          },
        ),
      ),
    );
  }
}
