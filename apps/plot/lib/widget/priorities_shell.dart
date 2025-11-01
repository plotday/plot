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

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (layoutState.multiPanel) {
          // Multi-panel mode: use standard AutoRouter
          return AutoRouter();
        } else {
          // Single-panel mode: use AutoTabsRouter with bottom navigation
          return BlocBuilder<NowBloc, NowState>(
            builder: (context, nowState) {
              if (nowState is! NowLoaded) {
                return AutoRouter();
              }

              final priorityId = nowState.priority.id.toShortString();

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
            },
          );
        }
      },
    );
  }
}
