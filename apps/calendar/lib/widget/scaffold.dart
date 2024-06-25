import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({required this.body, this.title, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosScaffold(
        toolBar: title == null
            ? null
            : macos.ToolBar(
                title: Text(title!),
              ),
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
                title: Text(title!),
              ),
        body: body,
      ),
    );
  }

  final Widget body;
  final String? title;
}
