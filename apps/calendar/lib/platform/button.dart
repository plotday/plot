import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

import 'style.dart';

class Button extends StatelessWidget {
  const Button({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.mac:
        return PushButton(
          onPressed: onTap,
          controlSize: ControlSize.regular,
          child: child,
        );
      default:
        return InkWell(onTap: onTap, child: child);
    }
  }
}
