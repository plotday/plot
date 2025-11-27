import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/bottom_navigation_provider.dart';
import 'package:plot/widget/icon.dart';

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget {
  const PrioritiesShell({super.key});

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();
}

class _PrioritiesShellState extends State<PrioritiesShell> with AutoRouteAware {
  AutoRouteObserver? _observer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route changes to rebuild bottom nav when navigating to/from NewActivityPage
    _observer = RouterScope.of(context).firstObserverOfType<AutoRouteObserver>();
    _observer?.subscribe(this, context.router.current);
  }

  @override
  void dispose() {
    _observer?.unsubscribe(this);
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
                // If on NewActivityPage (/priorityId/new), highlight New tab (index 2)
                if (currentPath.endsWith('/new')) {
                  return 2;
                }
                // Otherwise use the tab router's active index
                return tabsRouter.activeIndex;
              }

              return BottomNavigationScope(
                config: layoutState.multiPanel
                    ? null
                    : BottomNavigationConfig(
                        currentIndex: getCurrentIndex(),
                        onChange: (index) {
                          final currentPath = context.router.currentPath;

                          if (index == 2) {
                            // Navigate to New Activity for current priority
                            // Extract priorityId from the current route path
                            // Path format is "/:priorityId" or "/:priorityId/..."
                            final pathSegments = currentPath.split('/');
                            if (pathSegments.length > 1 && pathSegments[1].isNotEmpty) {
                              final priorityIdString = pathSegments[1];
                              context.router.navigate(
                                PriorityRoute(
                                  priorityIdString: priorityIdString,
                                  children: [NewActivityRoute()],
                                ),
                              );
                            }
                          } else if (index == 3) {
                            // Show command palette (same as Cmd-K)
                            Commands(
                              prompt: 'Run a command',
                              groups: CommandRegistry.of(context).commands,
                            ).show(context);
                          } else {
                            // If currently on NewActivityPage and switching to another tab
                            if (currentPath.endsWith('/new')) {
                              // Going back to Activities tab - just pop the NewActivityRoute
                              if (index == 1) {
                                context.router.back();
                              } else {
                                // Going to Priorities tab - pop first then switch tabs
                                context.router.back();
                                // Wait a frame for the pop to complete before switching tabs
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  tabsRouter.setActiveIndex(index);
                                });
                              }
                            } else {
                              // Normal tab switching
                              tabsRouter.setActiveIndex(index);
                            }
                          }
                        },
                        items: [
                          FBottomNavigationBarItem(
                            icon: Icon(PlotIcon.priorities),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('Priorities'),
                              ),
                            ),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(PlotIcon.activity),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('Activities'),
                              ),
                            ),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(PlotIcon.add),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('New'),
                              ),
                            ),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(PlotIcon.menu),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('More'),
                              ),
                            ),
                          ),
                        ],
                      ),
                child: child,
              );
            },
          );
        },
      ),
    );
  }
}
