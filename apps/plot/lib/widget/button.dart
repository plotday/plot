import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/widget/colour_scheme.dart';
import 'package:plot/command/command.dart';
import 'spinner.dart';

enum ButtonStyle { primary, secondary, ghost }

class Button extends StatelessWidget {
  const Button(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  })  : iconOnly = false,
        style = ButtonStyle.secondary;

  const Button.primary(
    this.command, {
    this.loading = false,
    this.enabled = true,
    super.key,
  })  : style = ButtonStyle.primary,
        iconOnly = false,
        selected = false;

  const Button.ghost(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  })  : style = ButtonStyle.ghost,
        iconOnly = false;

  Button.icon(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  })  : style = ButtonStyle.ghost,
        iconOnly = command.icon != null;

  final ButtonStyle style;
  final bool loading;
  final bool enabled;
  final bool selected;
  final bool iconOnly;
  final Command command;

  @override
  Widget build(BuildContext context) {
    FBaseButtonStyle fStyle;
    if (selected) {
      final baseStyle = switch (style) {
        ButtonStyle.primary => context.theme.buttonStyles.primary,
        ButtonStyle.secondary => context.theme.buttonStyles.outline,
        ButtonStyle.ghost => context.theme.buttonStyles.ghost,
      };
      fStyle = baseStyle.copyWith(
        contentStyle: baseStyle.contentStyle.copyWith(
          enabledTextStyle: baseStyle.contentStyle.enabledTextStyle.copyWith(
            color: context.colour.accent,
          ),
          enabledIconColor: context.colour.accent,
        ),
      );
    } else {
      fStyle = switch (style) {
        ButtonStyle.primary => FButtonStyle.primary,
        ButtonStyle.secondary => FButtonStyle.outline,
        ButtonStyle.ghost => FButtonStyle.ghost,
      };
    }

    final onPress = enabled ? () => command.run(context) : null;
    final button = PlatformBuilder(
      builder: (_) => iconOnly
          ? FButton.icon(
              style: fStyle,
              onPress: onPress,
              child: FIcon.data(
                command.icon!,
                size: 12,
              ),
            )
          : FButton(
              style: fStyle,
              onPress: onPress,
              prefix: command.icon != null
                  ? FIcon.data(
                      command.icon!,
                      size: 12,
                    )
                  : null,
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
