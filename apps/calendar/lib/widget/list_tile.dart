import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos_ui;
import 'package:platform_builder/platform_builder.dart';

class ListTile extends StatelessWidget {
  const ListTile({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos_ui.MacosListTile(title: child),
      builder: (_) => material.ListTile(title: child),
    );
  }

  final Widget child;
}
