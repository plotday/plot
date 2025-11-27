import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/command/command.dart';
import 'spinner.dart';

enum ButtonStyle { primary, secondary, ghost }

class Button extends StatelessWidget {
  const Button(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.expand = true,
    super.key,
  }) : iconOnly = false,
       style = ButtonStyle.secondary;

  const Button.primary(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.expand = true,
    super.key,
  }) : style = ButtonStyle.primary,
       iconOnly = false,
       selected = false;

  const Button.ghost(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.expand = true,
    super.key,
  }) : style = ButtonStyle.ghost,
       iconOnly = false;

  const Button.icon(
    this.command, {
    this.style = ButtonStyle.ghost,
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  }) : iconOnly = true,
       expand = false;

  final ButtonStyle style;
  final bool loading;
  final bool enabled;
  final bool selected;
  final bool iconOnly;
  final bool expand;
  final Command command;

  @override
  Widget build(BuildContext context) {
    FBaseButtonStyle Function(FButtonStyle) fStyle;
    if (selected) {
      fStyle = (baseStyle) {
        final selectedStyle = switch (style) {
          ButtonStyle.primary => context.theme.buttonStyles.primary,
          ButtonStyle.secondary => context.theme.buttonStyles.outline,
          ButtonStyle.ghost => context.theme.buttonStyles.ghost,
        };
        return selectedStyle.copyWith(
          // ignore: unused_result
          contentStyle: selectedStyle.contentStyle.copyWith(
            textStyle: selectedStyle.contentStyle.textStyle.map(
              (style) =>
                  style.copyWith(color: context.theme.colors.primaryForeground),
            ),
            iconStyle: selectedStyle.iconContentStyle.iconStyle.map(
              (style) =>
                  style.copyWith(color: context.theme.colors.primaryForeground),
            ),
          ),
          // ignore: unused_result
          iconContentStyle: selectedStyle.iconContentStyle.copyWith(
            iconStyle: selectedStyle.iconContentStyle.iconStyle.map(
              (style) =>
                  style.copyWith(color: context.theme.colors.primaryForeground),
            ),
          ),
        );
      };
    } else {
      fStyle = switch (style) {
        ButtonStyle.primary => FButtonStyle.primary(),
        ButtonStyle.secondary => FButtonStyle.outline(),
        ButtonStyle.ghost => FButtonStyle.ghost(),
      };
    }

    final onPress = enabled ? () => context.run(command) : null;
    final button = PlatformBuilder(
      builder: (_) {
        final icon = command.icon;
        return iconOnly
            ? FButton.icon(
                style: fStyle,
                onPress: onPress,
                child: icon != null
                    ? Icon(icon, size: 12)
                    : Text(
                        command.title,
                        style: context.theme.typography.base.copyWith(
                          height: 1,
                          textBaseline: TextBaseline.ideographic,
                        ),
                      ),
              )
            : FButton(
                style: fStyle,
                onPress: onPress,
                prefix: icon != null ? Icon(icon, size: 12) : null,
                child: Text(command.title),
              );
      },
    );

    final stack = Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: loading ? 0.0 : 1.0, child: button),
        if (loading) Spinner(),
      ],
    );

    Widget result = stack;

    result = FTooltip(
      tipBuilder: (context, controller) {
        if (command.subtitle != null && command.subtitle!.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(command.title),
              Text(
                command.subtitle!,
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ],
          );
        }
        return Text(command.title);
      },
      child: result,
    );

    if (!expand) {
      result = Row(mainAxisSize: MainAxisSize.min, children: [result]);
    }

    return result;
  }
}
