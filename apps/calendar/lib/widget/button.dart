import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'package:platform_builder/platform_builder.dart';

class Button extends StatelessWidget {
  const Button({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos.PushButton(
        onPressed: onTap,
        controlSize: macos.ControlSize.regular,
        child: child,
      ),
      builder: (_) => material.InkWell(onTap: onTap, child: child),
    );
  }
}

class IconButton extends StatelessWidget {
  const IconButton({required this.icon, required this.onPressed, super.key});

  final VoidCallback onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosIconButton(
        onPressed: onPressed,
        icon: icon,
      ),
      builder: (_) => material.IconButton(
        onPressed: onPressed,
        icon: icon,
      ),
    );
  }
}
