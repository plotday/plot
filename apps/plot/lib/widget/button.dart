import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

import 'spinner.dart';

enum ButtonStyle { primary, secondary }

class Button extends StatelessWidget {
  const Button({
    required this.child,
    required this.onTap,
    this.style = ButtonStyle.primary,
    this.loading = false,
    super.key,
  });

  final VoidCallback? onTap;
  final Widget child;
  final ButtonStyle style;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final button = PlatformBuilder(
      macOSBuilder: (_) => macos.PushButton(
        onPressed: onTap,
        controlSize: macos.ControlSize.regular,
        secondary: style == ButtonStyle.secondary,
        child: child,
      ),
      builder: (_) => style == ButtonStyle.primary
          ? material.FilledButton(
              onPressed: onTap,
              child: child,
            )
          : material.FilledButton.tonal(
              onPressed: onTap,
              child: child,
            ),
    );

    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(
          opacity: loading ? 0.0 : 1.0,
          child: button,
        ),
        if (loading) Spinner(),
      ],
    );
  }
}

class IconButton extends StatelessWidget {
  const IconButton({
    required this.icon,
    required this.onPressed,
    this.padding = const EdgeInsets.all(8),
    super.key,
  });

  final VoidCallback onPressed;
  final Widget icon;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosIconButton(
        padding: padding,
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
