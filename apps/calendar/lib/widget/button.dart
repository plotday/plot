import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:platform_builder/platform_builder.dart';

class Button extends StatelessWidget {
  const Button({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => PushButton(
        onPressed: onTap,
        controlSize: ControlSize.regular,
        child: child,
      ),
      builder: (_) => InkWell(onTap: onTap, child: child),
    );
  }
}

class IconButton extends StatelessWidget {
  const IconButton({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacosIconButton(
        onPressed: onTap,
        icon: child,
      ),
      builder: (_) => IconButton(onTap: onTap, child: child),
    );
  }
}
