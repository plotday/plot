import 'package:flutter/widgets.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:auto_route/auto_route.dart';

import "window.dart";
import "layout_material.dart";
import "layout_mac.dart";

class Layout extends StatelessWidget {
  const Layout(this.page, {required this.tabsRouter, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Window(
        child: MacLayout(page),
      ),
      builder: (_) => MaterialLayout(
        primary: page,
        tabsRouter: tabsRouter,
      ),
    );
  }

  final Widget page;
  final TabsRouter tabsRouter;
}
