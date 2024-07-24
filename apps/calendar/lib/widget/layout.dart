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
  const SingleLayout(this.page, {this.navigationShell, super.key});

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
  final StatefulNavigationShell? navigationShell;
}

final class DoubleLayout extends Layout {
  const DoubleLayout(this.left, this.right, {this.navigationShell, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacLayout(
        left,
        right,
        null,
        key: const Key('MacLayout'),
      ),
      builder: (_) => MaterialLayout(
        primary: left,
        secondary: right,
        navigationShell: navigationShell,
        key: const Key('MaterialLayout'),
      ),
    );
  }

  final Widget left;
  final Widget right;
  final StatefulNavigationShell? navigationShell;
}

final class TripleLayout extends Layout {
  static final _key = GlobalKey();

  const TripleLayout(this.first, this.second, this.third, {super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacLayout(
        first,
        second,
        third,
      ),
      builder: (_) => MaterialLayout(
        drawer: first,
        primary: second,
        secondary: third,
        key: _key,
      ),
    );
  }

  final Widget first;
  final Widget second;
  final Widget third;
}
