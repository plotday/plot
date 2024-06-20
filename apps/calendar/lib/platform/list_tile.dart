import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos_ui;

import 'style.dart';

class ListTile extends StatelessWidget {
  const ListTile({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return switch (style) {
      Style.mac => macos_ui.MacosListTile(title: child),
      _ => material.ListTile(title: child),
    };
  }

  final Widget child;
}
