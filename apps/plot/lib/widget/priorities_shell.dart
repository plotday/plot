import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/router.dart';

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget implements AutoRouteWrapper {
  const PrioritiesShell({super.key});

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();

  @override
  Widget wrappedRoute(BuildContext context) {
    return LayoutStateProvider(child: this);
  }
}

class _PrioritiesShellState extends State<PrioritiesShell> {
  int _tabIndex = 1; // Default to Activities tab (current priority)
  bool _previousMultiPanel = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        // Wait for NowBloc to be loaded before building any routes
        if (nowState is! NowLoaded) {
          return const SizedBox.shrink(); // Show nothing while loading
        }

        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            final priorityId = nowState.priority.id.toShortString();

            // Track mode changes
            if (layoutState.multiPanel && !_previousMultiPanel) {
              _previousMultiPanel = true;
            } else if (!layoutState.multiPanel && _previousMultiPanel) {
              _previousMultiPanel = false;
            }

            // In multi-panel mode, ensure we have a valid child route whenever panels are visible
            if (layoutState.multiPanel &&
                (layoutState.leftPanelVisible ||
                    layoutState.rightPanelVisible)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final router = context.router;
                final currentRoute = router.currentChild?.name;

                // Check if we don't have a valid PriorityRoute child
                if (currentRoute != 'PriorityRoute') {
                  router.navigate(PriorityRoute(priorityIdString: priorityId));
                }
              });
            }

            if (layoutState.multiPanel) {
              // Multi-panel mode: use standard AutoRouter
              return AutoRouter();
            } else {
              // Single-panel mode: use AutoTabsRouter with bottom navigation
              return AutoTabsRouter(
                routes: [
                  PrioritiesRoute(),
                  PriorityRoute(priorityIdString: priorityId),
                ],
                transitionBuilder: (context, child, animation) => child,
                builder: (context, child) {
                  final tabsRouter = AutoTabsRouter.of(context);
                  return FScaffold(
                    childPad: false,
                    footer: FBottomNavigationBar(
                      index: tabsRouter.activeIndex,
                      onChange: (index) {
                        setState(() {
                          _tabIndex = index;
                        });
                        tabsRouter.setActiveIndex(index);
                      },
                      children: [
                        FBottomNavigationBarItem(
                          icon: Icon(FIcons.list),
                          label: const Text('Priorities'),
                        ),
                        FBottomNavigationBarItem(
                          icon: Icon(FIcons.calendar),
                          label: const Text('Activities'),
                        ),
                      ],
                    ),
                    child: child,
                  );
                },
              );
            }
          },
        );
      },
    );
  }
}
