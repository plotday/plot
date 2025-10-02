import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/router.dart';

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends AutoRouter implements AutoRouteWrapper {
  const PrioritiesShell({super.key});

  @override
  Widget wrappedRoute(BuildContext context) {
    return LayoutStateProvider(
      child: BlocBuilder<LayoutBloc, LayoutState>(
        builder: (context, layoutState) {
          return AutoTabsRouter(
            routes: [PrioritiesRoute(), PriorityRoute()],
            builder: (context, child) {
              final tabsRouter = AutoTabsRouter.of(context);
              if (layoutState.multiPanel) {
                return child;
              } else {
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
              }
            },
          );
        },
      ),
    );
  }
}
