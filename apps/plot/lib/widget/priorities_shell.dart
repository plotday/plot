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
  String? _lastKnownPriorityId;
  bool _isNavigating = false;
  bool _hasNavigatedOnce = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        // Wait for NowBloc to be loaded before building any routes
        if (nowState is! NowLoaded) {
          return const SizedBox.shrink(); // Show nothing while loading
        }

        final priorityId = nowState.priority.id.toShortString();
        final sessionPriorityId = nowState.session?.priority?.id.toShortString();
        final sessionExists = nowState.session != null;

        // Track the priority ID, but only update when we have a valid session
        // This prevents flickering when the session temporarily becomes null during transitions
        if (sessionExists) {
          _lastKnownPriorityId = sessionPriorityId;
        }

        // Use the last known priority ID when session is null (during transition)
        final stablePriorityId = sessionExists ? priorityId : (_lastKnownPriorityId ?? priorityId);

        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {

            // Track mode changes
            final modeChanged = layoutState.multiPanel != _previousMultiPanel;
            if (modeChanged) {
              _previousMultiPanel = layoutState.multiPanel;
              // Reset navigation flags when mode changes
              _hasNavigatedOnce = false;
            }

            // In multi-panel mode, ensure we have a valid child route
            // Only navigate ONCE on initial mount or when mode changes
            if (layoutState.multiPanel &&
                (layoutState.leftPanelVisible || layoutState.rightPanelVisible) &&
                !_isNavigating &&
                !_hasNavigatedOnce) {

              WidgetsBinding.instance.addPostFrameCallback((_) {
                // Double-check we're still in a state where we should navigate
                if (_isNavigating || _hasNavigatedOnce) {
                  return;
                }

                _isNavigating = true;
                _hasNavigatedOnce = true;

                context.router.navigate(PriorityRoute(priorityIdString: stablePriorityId)).then((_) {
                  // Clear the navigation flag after a short delay
                  Future.microtask(() {
                    if (mounted) {
                      setState(() {
                        _isNavigating = false;
                      });
                    }
                  });
                });
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
