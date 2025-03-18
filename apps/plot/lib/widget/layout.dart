import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:platform_builder/platform_builder.dart';

import "window.dart";
import "layout_material.dart";
import "layout_mac.dart";

class Layout extends StatelessWidget {
  const Layout(this.page, {required this.navigationShell, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Window(
        child: MacLayout(page),
      ),
      builder: (_) => MaterialLayout(
        primary: page,
        navigationShell: navigationShell,
      ),
    );
  }

  final Widget page;
  final StatefulNavigationShell navigationShell;
}
