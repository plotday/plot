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
  bool _previousMultiPanel = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        // Wait for NowBloc to be loaded before building any routes
        if (nowState is! NowLoaded) {
          return const SizedBox.shrink(); // Show nothing while loading
        }

        final priorityId = nowState.priority.id.toShortString();

        // Use the last known priority ID when session is null (during transition)
        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            // Track mode changes
            final modeChanged = layoutState.multiPanel != _previousMultiPanel;
            if (modeChanged) {
              _previousMultiPanel = layoutState.multiPanel;
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
                        tabsRouter.setActiveIndex(index);
                      },
                      children: [
                        FBottomNavigationBarItem(
                          icon: Icon(FIcons.list),
                          label: Builder(
                            builder: (context) => DefaultTextStyle(
                              style: context.theme.typography.sm,
                              child: const Text('Priorities'),
                            ),
                          ),
                        ),
                        FBottomNavigationBarItem(
                          icon: Icon(FIcons.calendar),
                          label: Builder(
                            builder: (context) => DefaultTextStyle(
                              style: context.theme.typography.sm,
                              child: const Text('Activities'),
                            ),
                          ),
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
