import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/command/command.dart';
import 'spinner.dart';

enum ButtonStyle { primary, secondary, icon }

class Button extends StatelessWidget {
  const Button(
    this.command, {
    this.style = ButtonStyle.primary,
    this.loading = false,
    this.enabled = true,
    super.key,
  });

  const Button.secondary(
    this.command, {
    this.loading = false,
    this.enabled = true,
    super.key,
  }) : style = ButtonStyle.secondary;
  const Button.icon(
    this.command, {
    this.loading = false,
    this.enabled = true,
    super.key,
  }) : style = ButtonStyle.icon;

  final ButtonStyle style;
  final bool loading;
  final bool enabled;
  final Command command;

  @override
  Widget build(BuildContext context) {
    final onPress = enabled ? () => command.run(context) : null;
    final button = PlatformBuilder(
      builder: (_) => style == ButtonStyle.icon && command.icon != null
          ? FButton.icon(
              style: FButtonStyle.ghost,
              onPress: () => onPress,
              child: FIcon.data(
                command.icon!,
                size: 12,
              ),
            )
          : FButton(
              style: style == ButtonStyle.primary
                  ? FButtonStyle.primary
                  : FButtonStyle.secondary,
              onPress: () => onPress,
              label: Text(command.title),
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
