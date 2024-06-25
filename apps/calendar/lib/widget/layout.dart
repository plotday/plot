import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:platform_builder/platform_builder.dart';

import "layout_material.dart";
import "layout_mac.dart";

enum PanelLayout {
  single,
  double,
  triple,
}

sealed class Layout extends StatelessWidget {
  static PanelLayout getLayout(BuildContext context) {
    return PlatformResolver.current(
      nativeResolver: () {
        final size = MediaQuery.sizeOf(context);
        return size.width > 1024 ? PanelLayout.triple : PanelLayout.double;
      },
      defaultResolver: () {
        final size = MediaQuery.sizeOf(context);
        return size.width > 1024
            ? PanelLayout.triple
            : size.width > 600
                ? PanelLayout.double
                : PanelLayout.single;
      },
    );
  }

  const Layout({super.key});
}

final class SingleLayout extends Layout {
  const SingleLayout(this.navigationShell, this.page, {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => MaterialLayout(
        primary: page,
        navigationShell: navigationShell,
        key: const Key('MaterialLayout'),
      ),
    );
  }

  final Widget page;
  final StatefulNavigationShell navigationShell;
}

final class DoubleLayout extends Layout {
  const DoubleLayout(this.navigationShell, this.primary, this.secondary,
      {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => MaterialLayout(
        primary: primary,
        secondary: secondary,
        navigationShell: navigationShell,
        key: const Key('MaterialLayout'),
      ),
    );
  }

  final Widget primary;
  final Widget secondary;
  final StatefulNavigationShell navigationShell;
}

final class TripleLayout extends Layout {
  const TripleLayout(this.drawer, this.primary, this.secondary, {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacLayout(
        drawer,
        primary,
        secondary,
        key: const Key('MacLayout'),
      ),
      builder: (_) => MaterialLayout(
        primary: primary,
        secondary: secondary,
        drawer: drawer,
        key: const Key('MaterialLayout'),
      ),
    );
  }

  final Widget primary;
  final Widget secondary;
  final Widget drawer;
}
