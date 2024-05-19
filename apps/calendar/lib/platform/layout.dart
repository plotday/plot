import 'package:flutter/widgets.dart';

import 'style.dart';
import 'layout_material.dart';
import 'layout_mac.dart';

enum PanelLayout {
  single,
  double,
  triple,
}

class Layout extends StatelessWidget {
  static PanelLayout getLayout(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return switch (style) {
      Style.mac || Style.windows => PanelLayout.triple,
      Style.ios => size.width > 600 ? PanelLayout.double : PanelLayout.single,
      Style.material => MaterialLayout.getLayout(context),
    };
  }

  const Layout(this.panels, {super.key});

  @override
  Widget build(BuildContext context) {
    assert(panels.isNotEmpty);
    switch (style) {
      case Style.mac:
        assert(panels.length == 3);
        return MacLayout(panels);
      case Style.ios:
        assert(panels.length <= 2);
        return const Text("TODO");
      case Style.material:
        assert(panels.length <= 3);
        return MaterialLayout(panels);
      case Style.windows:
        assert(panels.length == 3);
        return const Text("TODO");
    }
  }

  final List<Widget> panels;
}
