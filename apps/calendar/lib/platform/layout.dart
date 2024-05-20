import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'style.dart';
import 'layout_material.dart';
import 'layout_mac.dart';

enum PanelLayout {
  single,
  double,
  triple,
}

sealed class Layout extends StatelessWidget {
  static PanelLayout getLayout(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return switch (style) {
      Style.mac || Style.windows => PanelLayout.triple,
      Style.ios => size.width > 600 ? PanelLayout.double : PanelLayout.single,
      Style.material => MaterialLayout.getLayout(context),
    };
  }

  const Layout({super.key});
}

final class SingleLayout extends Layout {
  const SingleLayout(this.navigationShell, this.page, {super.key});

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.material:
        return MaterialLayout(
          primary: page,
          navigationShell: navigationShell,
          key: const Key('MaterialLayout'),
        );
      default:
        throw UnsupportedError("SingleLayout not supported for $style");
    }
  }

  final Widget page;
  final StatefulNavigationShell navigationShell;
}

final class DoubleLayout extends Layout {
  const DoubleLayout(this.navigationShell, this.primary, this.secondary,
      {super.key});

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.material:
        return MaterialLayout(
          primary: primary,
          secondary: secondary,
          navigationShell: navigationShell,
          key: const Key('MaterialLayout'),
        );
      default:
        throw UnsupportedError("DoubleLayout not supported for $style");
    }
  }

  final Widget primary;
  final Widget secondary;
  final StatefulNavigationShell navigationShell;
}

final class TripleLayout extends Layout {
  const TripleLayout(this.drawer, this.primary, this.secondary, {super.key});

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.mac:
        return MacLayout(drawer, primary, secondary);
      case Style.material:
        return MaterialLayout(
          primary: primary,
          secondary: secondary,
          drawer: drawer,
          key: const Key('MaterialLayout'),
        );
      default:
        throw UnsupportedError("TripleLayout not supported for $style");
    }
  }

  final Widget primary;
  final Widget secondary;
  final Widget drawer;
}
