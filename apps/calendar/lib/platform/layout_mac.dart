import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'scroll_context.dart';

class MacLayout extends StatefulWidget {
  const MacLayout(this.drawer, this.primary, this.secondary, {super.key});

  @override
  State<MacLayout> createState() {
    return MacLayoutState();
  }

  final Widget primary;
  final Widget secondary;
  final Widget drawer;
}

class MacLayoutState extends State<MacLayout> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MacosWindow(
      sidebar: Sidebar(
        minWidth: 200,
        builder: (context, scrollController) {
          return ScrollControllerContext(
            controller: scrollController,
            child: widget.drawer,
          );
        },
      ),
      endSidebar: Sidebar(
        startWidth: 200,
        minWidth: 200,
        maxWidth: 300,
        shownByDefault: true,
        builder: (context, _) {
          return widget.secondary;
        },
      ),
      child: widget.primary,
    );
  }
}
