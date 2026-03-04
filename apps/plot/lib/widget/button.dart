import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'spinner.dart';

enum ButtonStyle { primary, secondary, ghost }

class Button extends StatefulWidget {
  const Button(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.selectedColor,
    this.expand = true,
    super.key,
  }) : iconOnly = false,
       style = ButtonStyle.secondary,
       color = null,
       forceHover = false;

  const Button.primary(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.expand = true,
    super.key,
  }) : style = ButtonStyle.primary,
       iconOnly = false,
       selected = false,
       selectedColor = null,
       color = null,
       forceHover = false;

  const Button.ghost(
    this.command, {
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.selectedColor,
    this.expand = true,
    super.key,
  }) : style = ButtonStyle.ghost,
       iconOnly = false,
       color = null,
       forceHover = false;

  const Button.icon(
    this.command, {
    this.style = ButtonStyle.ghost,
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.selectedColor,
    this.color,
    this.forceHover = false,
    super.key,
  }) : iconOnly = true,
       expand = false;

  final ButtonStyle style;
  final bool loading;
  final bool enabled;
  final bool selected;
  final Color? selectedColor;
  /// Color override for non-selected state icon/text.
  final Color? color;
  final bool forceHover;
  final bool iconOnly;
  final bool expand;
  final Command command;

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    FBaseButtonStyle Function(FButtonStyle) fStyle;
    if (widget.selected) {
      fStyle = (baseStyle) {
        // Ghost selected: keep ghost decoration, just color the text/icon
        // Primary/secondary selected: use primary style (tint background)
        var style = widget.style == ButtonStyle.ghost
            ? context.theme.buttonStyles.ghost
            : context.theme.buttonStyles.primary;

        if (widget.iconOnly) {
          style = style.copyWith(
            decoration: style.decoration.map(
              (d) => d.copyWith(borderRadius: BorderRadius.circular(999)),
            ),
          );
        }

        final color = widget.selectedColor ?? context.theme.colors.primary;

        if (widget.style == ButtonStyle.ghost) {
          // Ghost selected: override text/icon color only
          final hoverColor = Color.lerp(
            color,
            context.colour.foreground,
            0.3,
          );
          style = style.copyWith(
            // ignore: unused_result
            contentStyle: style.contentStyle.copyWith(
              textStyle: FWidgetStateMap({
                WidgetState.hovered | WidgetState.pressed:
                    style.contentStyle.textStyle
                        .resolve({WidgetState.hovered})
                        .copyWith(color: hoverColor),
                WidgetState.any: style.contentStyle.textStyle
                    .resolve({})
                    .copyWith(color: color),
              }),
              iconStyle: FWidgetStateMap({
                WidgetState.hovered | WidgetState.pressed:
                    style.contentStyle.iconStyle
                        .resolve({WidgetState.hovered})
                        .copyWith(color: hoverColor),
                WidgetState.any: style.contentStyle.iconStyle
                    .resolve({})
                    .copyWith(color: color),
              }),
            ),
            // ignore: unused_result
            iconContentStyle: style.iconContentStyle.copyWith(
              iconStyle: FWidgetStateMap({
                WidgetState.hovered | WidgetState.pressed:
                    style.iconContentStyle.iconStyle
                        .resolve({WidgetState.hovered})
                        .copyWith(color: hoverColor),
                WidgetState.any: style.iconContentStyle.iconStyle
                    .resolve({})
                    .copyWith(color: color),
              }),
            ),
          );
        } else if (widget.selectedColor != null) {
          // Primary/secondary selected with custom color: tint with selectedColor
          final oklch = widget.selectedColor!.toRayRgb8().toOklch();
          final colourScheme = context.colour;
          final isLight = colourScheme.brightness == Brightness.light;

          final bgColor = oklch
              .withLightness(isLight ? 0.94 : 0.26)
              .withChroma(isLight ? 0.04 : 0.03)
              .toColor();
          final hoverBgColor = oklch
              .withLightness(isLight ? 0.90 : 0.30)
              .withChroma(isLight ? 0.06 : 0.05)
              .toColor();
          final borderColor = oklch.withOpacity(0.35).toColor();
          final hoverBorderColor = oklch.withOpacity(0.5).toColor();
          final fgColor = widget.selectedColor!;

          style = style.copyWith(
            // ignore: unused_result
            decoration: FWidgetStateMap({
              WidgetState.hovered | WidgetState.pressed: BoxDecoration(
                borderRadius: widget.iconOnly
                    ? BorderRadius.circular(999)
                    : style.decoration.resolve({}).borderRadius
                        as BorderRadius?,
                color: hoverBgColor,
                border: Border.all(color: hoverBorderColor),
              ),
              WidgetState.any: BoxDecoration(
                borderRadius: widget.iconOnly
                    ? BorderRadius.circular(999)
                    : style.decoration.resolve({}).borderRadius
                        as BorderRadius?,
                color: bgColor,
                border: Border.all(color: borderColor),
              ),
            }),
            // ignore: unused_result
            contentStyle: style.contentStyle.copyWith(
              textStyle: FWidgetStateMap({
                WidgetState.any: style.contentStyle.textStyle
                    .resolve({})
                    .copyWith(color: fgColor),
              }),
              iconStyle: FWidgetStateMap({
                WidgetState.any: style.contentStyle.iconStyle
                    .resolve({})
                    .copyWith(color: fgColor),
              }),
            ),
            // ignore: unused_result
            iconContentStyle: style.iconContentStyle.copyWith(
              iconStyle: FWidgetStateMap({
                WidgetState.any: style.iconContentStyle.iconStyle
                    .resolve({})
                    .copyWith(color: fgColor),
              }),
            ),
          );
        }

        return style;
      };
    } else {
      fStyle = switch (widget.style) {
        ButtonStyle.primary => FButtonStyle.primary(),
        ButtonStyle.secondary => FButtonStyle.secondary(),
        ButtonStyle.ghost => FButtonStyle.ghost(),
      };

      // Apply circular border radius and optional color for icon buttons
      if (widget.iconOnly) {
        fStyle = (baseStyle) {
          final unselectedStyle = switch (widget.style) {
            ButtonStyle.primary => context.theme.buttonStyles.primary,
            ButtonStyle.secondary => context.theme.buttonStyles.secondary,
            ButtonStyle.ghost => context.theme.buttonStyles.ghost,
          };

          var result = unselectedStyle.copyWith(
            decoration: unselectedStyle.decoration.map(
              (decoration) =>
                  decoration.copyWith(borderRadius: BorderRadius.circular(999)),
            ),
          );

          if (widget.color != null) {
            final iconStyle = result.iconContentStyle.iconStyle;
            result = result.copyWith(
              // ignore: unused_result
              iconContentStyle: result.iconContentStyle.copyWith(
                iconStyle: FWidgetStateMap({
                  WidgetState.hovered | WidgetState.pressed:
                      iconStyle.resolve({WidgetState.hovered}),
                  WidgetState.any:
                      iconStyle.resolve({}).copyWith(color: widget.color),
                }),
              ),
            );
          }

          return result;
        };
      }
    }

    final onPress = widget.enabled && widget.command.enabled(context)
        ? () => context.run(widget.command)
        : null;

    final button = MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _isHovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _isHovered = false) : null,
      child: PlatformBuilder(
        builder: (_) {
          // Priority order for icon display:
          // 1. buildIcon() - custom icon widget
          // 2. icon/hoverIcon - IconData
          // 3. buildBody() - custom body widget
          // 4. Text(title) - fallback

          // Determine if button is being hovered
          final isHovering = widget.forceHover || _isHovered;

          // Check for custom icon widget first
          final customIcon = widget.command.buildIcon(context, hoverIcon: isHovering);

          // Determine which icon to show (if no custom icon)
          var icon = widget.command.icon;
          if (widget.command.hoverIcon != null &&
              (widget.forceHover || _isHovered)) {
            // Use hover icon when hovering and hoverIcon is specified
            icon = widget.command.hoverIcon;
          }

          return widget.iconOnly
              ? FButton.icon(
                  style: fStyle,
                  onPress: onPress,
                  child: customIcon ??
                      (icon != null
                          ? Icon(icon, size: context.theme.iconSizes.base)
                          : (widget.command.buildBody(context) ??
                                Text(
                                  widget.command.title,
                                  style: context.theme.typography.base.copyWith(
                                    height: 1,
                                    textBaseline: TextBaseline.ideographic,
                                  ),
                                ))),
                )
              : FButton(
                  style: fStyle,
                  onPress: onPress,
                  prefix: icon != null
                      ? Icon(icon, size: context.theme.iconSizes.base)
                      : null,
                  child: Text(widget.command.title),
                );
        },
      ),
    );

    return _wrapButton(button);
  }

  Widget _wrapButton(Widget button) {
    final stack = Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: widget.loading ? 0.0 : 1.0, child: button),
        if (widget.loading) Spinner(),
      ],
    );

    Widget result = stack;

    result = FTooltip(
      tipBuilder: (context, controller) {
        final hasSubtitle = widget.command.subtitle != null &&
            widget.command.subtitle!.isNotEmpty;
        final shortcutText = hasPhysicalKeyboard() &&
                widget.command.shortcut != null
            ? formatShortcut(widget.command.shortcut)
            : '';

        if (hasSubtitle || shortcutText.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.command.title),
              if (hasSubtitle)
                Text(
                  widget.command.subtitle!,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
              if (shortcutText.isNotEmpty)
                Text(
                  shortcutText,
                  style: context.theme.typography.sm.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
            ],
          );
        }
        return Text(widget.command.title);
      },
      child: result,
    );

    if (!widget.expand) {
      result = Row(mainAxisSize: MainAxisSize.min, children: [result]);
    }

    return result;
  }
}
