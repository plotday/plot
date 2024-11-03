import 'package:flutter/material.dart';
import 'package:flutter_adaptive_scaffold/flutter_adaptive_scaffold.dart';
import 'package:go_router/go_router.dart';

import 'activity_nav.dart';

class MaterialLayout extends StatelessWidget {
  static const singleBreakpoint = WidthPlatformBreakpoint(end: 600);
  static const doubleBreakpoint = WidthPlatformBreakpoint(begin: 600, end: 840);
  static const tripleBreakpoint = WidthPlatformBreakpoint(begin: 840);
  static const navBreakpoint = WidthPlatformBreakpoint(end: 840);
  static const allBreakpoints = WidthPlatformBreakpoint();
  static const secondaryBreakpoint = WidthPlatformBreakpoint(begin: 600);

  static int numPanels(BuildContext context) =>
      singleBreakpoint.isActive(context)
          ? 1
          : doubleBreakpoint.isActive(context)
              ? 2
              : 3;

  const MaterialLayout(
      {required this.primary,
      this.secondary,
      this.drawer,
      this.navigationShell,
      super.key});

  // Displayed at all breakpoints
  final Widget primary;
  // Displayed at double and triple breakpoints
  final Widget? secondary;
  // Displayed at triple breakpoints
  final Widget? drawer;
  // Displayed at single and double breakpoints
  final StatefulNavigationShell? navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const ActivityNav(),
      ),
      body: AdaptiveLayout(
        key: const Key('Global Layout'),
        primaryNavigation: SlotLayout(
          config: <Breakpoint, SlotLayoutConfig>{
            MaterialLayout.tripleBreakpoint: SlotLayout.from(
              key: const Key('Drawer'),
              builder: (_) => SizedBox(
                width: 240,
                child: drawer!,
              ),
            ),
          },
        ),
        body: SlotLayout(
          config: <Breakpoint, SlotLayoutConfig>{
            MaterialLayout.allBreakpoints: SlotLayout.from(
              key: const Key('Primary'),
              builder: (_) => primary,
            ),
          },
        ),
        secondaryBody: SlotLayout(
          config: <Breakpoint, SlotLayoutConfig>{
            MaterialLayout.secondaryBreakpoint: SlotLayout.from(
              key: const Key('Secondary'),
              builder: (_) => secondary!,
            ),
          },
        ),
        bottomNavigation: SlotLayout(
          config: <Breakpoint, SlotLayoutConfig>{
            MaterialLayout.navBreakpoint: SlotLayout.from(
              key: const Key('Bottom Navigation'),
              inAnimation: AdaptiveScaffold.bottomToTop,
              outAnimation: AdaptiveScaffold.topToBottom,
              builder: navigationShell == null
                  ? null
                  : (_) => AdaptiveScaffold.standardBottomNavigationBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.calendar_today),
                            label: 'Schedule',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.crisis_alert),
                            label: 'Priorities',
                          ),
                          // NavigationDestination(
                          //   icon: Icon(Icons.schedule),
                          //   label: 'Now',
                          // ),
                          // NavigationDestination(
                          //   icon: Icon(Icons.settings),
                          //   label: 'Settings',
                          // ),
                        ],
                        currentIndex: navigationShell!.currentIndex,
                        onDestinationSelected: (int index) {
                          if (navigationShell == null) return;
                          navigationShell!.goBranch(index);
                        },
                      ),
            )
          },
        ),
      ),
    );
  }
}
