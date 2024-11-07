import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:device_info_plus/device_info_plus.dart';

import "layout_material.dart";
import "layout_mac.dart";

enum PanelLayout {
  single,
  adaptive,
}

sealed class Layout extends StatelessWidget {
  static Future<PanelLayout> getLayout(BuildContext context) async {
    return PlatformResolver.current(
      iOSResolver: () async {
        final deviceInfo = DeviceInfoPlugin();
        final iosDeviceInfo = await deviceInfo.iosInfo;
        return iosDeviceInfo.model.toLowerCase().contains('iphone')
            ? PanelLayout.single
            : PanelLayout.adaptive;
      },
      androidResolver: () {
        double screenWidth = MediaQuery.of(context).size.shortestSide;
        return screenWidth <= 600 ? PanelLayout.single : PanelLayout.adaptive;
      },
      defaultResolver: () {
        return PanelLayout.adaptive;
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

final class AdaptiveLayout extends Layout {
  const AdaptiveLayout(this.left, this.main, this.right, {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacLayout(
        left,
        main,
        right,
      ),
      builder: (_) => MaterialLayout(
        drawer: left,
        primary: main,
        secondary: right,
      ),
    );
  }

  final Widget left;
  final Widget main;
  final Widget right;
}
