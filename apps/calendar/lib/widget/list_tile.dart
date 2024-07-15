import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos_ui;
import 'package:platform_builder/platform_builder.dart';

class ListTile extends StatelessWidget {
  const ListTile({required this.child, this.onTap, super.key});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos_ui.MacosListTile(
        onClick: onTap,
        title: child,
      ),
      builder: (_) => material.ListTile(
        onTap: onTap,
        title: child,
      ),
    );
  }

  final Widget child;
}
