import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:device_info_plus/device_info_plus.dart';

import "window.dart";
import "layout_material.dart";
import "layout_mac.dart";

enum PanelLayout {
  tabbed, // mobile layout with tabs using bottom navigation
  sidebar, // desktop layout with two sidebars
}

sealed class Layout extends StatelessWidget {
  static late final PanelLayout layout;

  static Future<PanelLayout> init(BuildContext context) async {
    return layout = await PlatformResolver.current(
      iOSResolver: () async {
        final deviceInfo = DeviceInfoPlugin();
        final iosDeviceInfo = await deviceInfo.iosInfo;
        return iosDeviceInfo.model.toLowerCase().contains('iphone')
            ? PanelLayout.tabbed
            : PanelLayout.sidebar;
      },
      androidResolver: () {
        double screenWidth = MediaQuery.of(context).size.shortestSide;
        return screenWidth <= 600 ? PanelLayout.tabbed : PanelLayout.sidebar;
      },
      defaultResolver: () {
        return PanelLayout.sidebar;
      },
    );
  }

  const Layout({super.key});
}

final class TabbedLayout extends Layout {
  const TabbedLayout(this.page, {required this.navigationShell, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => MaterialLayout(
        primary: page,
        navigationShell: navigationShell,
      ),
    );
  }

  final Widget page;
  final StatefulNavigationShell navigationShell;
}

final class FullPageLayout extends Layout {
  const FullPageLayout(this.page, {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => MaterialLayout(
        primary: page,
      ),
    );
  }

  final Widget page;
}

final class SidebarLayout extends Layout {
  const SidebarLayout(
    this.left,
    this.main,
    this.right, {
    this.header,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Window(
        child: MacLayout(
          left,
          main,
          right,
          header: header,
        ),
      ),
      builder: (_) => MaterialLayout(
        drawer: left,
        primary: main,
        secondary: right,
        header: header,
      ),
    );
  }

  final Widget left;
  final Widget main;
  final Widget right;
  final Widget? header;
}
