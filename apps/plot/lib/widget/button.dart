import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter/material.dart' as material;
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
      androidBuilder: (_) => style == ButtonStyle.primary
          ? material.FilledButton(
              onPressed: onTap,
              child: child,
            )
          : material.FilledButton.tonal(
              onPressed: onTap,
              child: child,
            ),
      builder: (_) => FButton(
        onPress: onTap,
        label: child,
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
    super.key,
  });

  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      androidBuilder: (_) => material.IconButton(
        onPressed: onPressed,
        icon: material.Icon(icon),
      ),
      builder: (_) => FButton.icon(
        style: FButtonStyle.ghost,
        onPress: onPressed,
        child: FIcon.data(icon, size: 14),
      ),
    );
  }
}
