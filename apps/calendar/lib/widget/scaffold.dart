import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

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
    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosScaffold(
        toolBar: title != null || actions != null
            ? macos.ToolBar(
                title: title,
                actions: actions
                    ?.map(
                      (action) => macos.ToolBarIconButton(
                        icon: action.icon,
                        label: action.label,
                        showLabel: action.showLabel,
                        onPressed: action.onPressed,
                      ),
                    )
                    .toList(),
              )
            : null,
        children: [
          macos.ContentArea(
            builder: (_, __) => body,
          )
        ],
      ),
      builder: (_) => material.Scaffold(
        appBar: title == null
            ? null
            : material.AppBar(
                title: title!,
              ),
        body: body,
      ),
    );
  }

  final Widget body;
  final Widget? title;
  final List<ActionItem>? actions;
}
