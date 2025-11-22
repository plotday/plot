import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/bottom_navigation_provider.dart';

@RoutePage(name: "PrioritiesShellRoute")
class PrioritiesShell extends StatefulWidget {
  const PrioritiesShell({super.key});

  @override
  State<PrioritiesShell> createState() => _PrioritiesShellState();
}

class _PrioritiesShellState extends State<PrioritiesShell> {
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
              return BottomNavigationScope(
                config: layoutState.multiPanel
                    ? null
                    : BottomNavigationConfig(
                        currentIndex: tabsRouter.activeIndex,
                        onChange: (index) {
                          if (index == 2) {
                            // Show command palette (same as Cmd-K)
                            Commands(
                              prompt: 'Run a command',
                              groups: CommandRegistry.of(context).commands,
                            ).show(context);
                          } else {
                            tabsRouter.setActiveIndex(index);
                          }
                        },
                        items: [
                          FBottomNavigationBarItem(
                            icon: Icon(FIcons.list),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('Priorities'),
                              ),
                            ),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(FIcons.calendar),
                            label: Builder(
                              builder: (context) => DefaultTextStyle(
                                style: context.theme.typography.base,
                                child: const Text('Activities'),
                              ),
                            ),
                          ),
                          FBottomNavigationBarItem(
                            icon: Icon(FIcons.command),
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
