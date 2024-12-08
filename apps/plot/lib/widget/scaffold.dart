import 'package:flutter/widgets.dart';

import 'app.dart';
import 'button.dart';

class ActionItem {
  const ActionItem({
    required this.icon,
    required this.label,
    this.showLabel = true,
    required this.onPressed,
  });
  final Widget icon;
  final String label;
  final bool showLabel;
  final VoidCallback onPressed;
}

class Scaffold extends StatelessWidget {
  const Scaffold({required this.body, this.title, this.actions, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final hasToolbar = title != null || actions != null;
        final topPadding = hasToolbar ? AppWidget.toolbarHeight : 0.0;

        return Stack(
          children: [
            Positioned(
              top: 0,
              width: width,
              height: height,
              child: Padding(
                padding: EdgeInsets.only(top: topPadding),
                child: body,
              ),
            ),

            // Toolbar
            if (hasToolbar)
              Positioned(
                width: width,
                height: AppWidget.toolbarHeight,
                child: Builder(builder: (BuildContext context) {
                  final RenderBox? renderBox =
                      context.findRenderObject() as RenderBox?;
                  EdgeInsetsGeometry padding = EdgeInsets.zero;
                  if (renderBox != null) {
                    final pos = renderBox.localToGlobal(Offset.zero);
                    if (pos.dx == 0 && pos.dy == 0) {
                      padding = AppWidget.toolbarPadding;
                    }
                  }
                  return Padding(
                    padding: padding,
                    child: Row(
                      children: [
                        if (title != null) title!,
                        const Expanded(
                          child: SizedBox(),
                        ),
                        ...(actions ?? []).map(
                          (action) => IconButton(
                            icon: action.icon,
                            // label: action.label,
                            // showLabel: action.showLabel,
                            onPressed: action.onPressed,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
          ],
        );
      },
    );
  }

  final Widget body;
  final Widget? title;
  final List<ActionItem>? actions;
}
