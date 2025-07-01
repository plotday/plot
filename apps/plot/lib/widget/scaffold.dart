import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

// import 'package:plot/router.dart';
import 'colour_scheme.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.sidebar,
    this.translucent = false,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final Widget? sidebar;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      androidBuilder: (_) => material.Material(
        child:
            // AutoTabsRouter(
            //   routes: [PrioritiesRoute(), PriorityRoute()],
            //   builder: (context, child) {
            //     final tabsRouter = AutoTabsRouter.of(context);
            FScaffold(
              header: header,
              // footer: FBottomNavigationBar(
              //   index: tabsRouter.activeIndex,
              //   onChange: (index) => tabsRouter.setActiveIndex(index),
              //   children: [
              //     FBottomNavigationBarItem(
              //       icon: Icon(FIcons.house),
              //       label: const Text('Priorities'),
              //     ),
              //     FBottomNavigationBarItem(
              //       icon: Icon(FIcons.house),
              //       label: const Text('Now'),
              //     ),
              //   ],
              // ),
              childPad: false,
              child: body,
            ),
      ),
      webBuilder: (_) => material.Material(
        child: FScaffold(
          header: header,
          sidebar: sidebar,
          childPad: false,
          child: body,
        ),
      ),
      builder: (_) => Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: translucent ? null : context.colour.background,
          child: FScaffold(
            header: header,
            sidebar: sidebar,
            childPad: false,
            child: body,
          ),
        ),
      ),
    );
  }
}
