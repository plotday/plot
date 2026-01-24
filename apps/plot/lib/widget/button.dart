import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/command/command.dart';
import 'package:plot/style/plot_icon_sizes.dart';
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
       forceHover = false;

  const Button.icon(
    this.command, {
    this.style = ButtonStyle.ghost,
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.selectedColor,
    this.forceHover = false,
    super.key,
  }) : iconOnly = true,
       expand = false;

  final ButtonStyle style;
  final bool loading;
  final bool enabled;
  final bool selected;
  final Color? selectedColor;
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
        final selectedStyle = switch (widget.style) {
          ButtonStyle.primary => context.theme.buttonStyles.primary,
          ButtonStyle.secondary => context.theme.buttonStyles.outline,
          ButtonStyle.ghost => context.theme.buttonStyles.ghost,
        };
        final color = widget.selectedColor ?? context.theme.colors.primary;
        var result = selectedStyle.copyWith(
          // ignore: unused_result
          contentStyle: selectedStyle.contentStyle.copyWith(
            textStyle: selectedStyle.contentStyle.textStyle.map(
              (style) => style.copyWith(color: color),
            ),
            iconStyle: selectedStyle.iconContentStyle.iconStyle.map(
              (style) => style.copyWith(color: color),
            ),
          ),
          // ignore: unused_result
          iconContentStyle: selectedStyle.iconContentStyle.copyWith(
            iconStyle: selectedStyle.iconContentStyle.iconStyle.map(
              (style) => style.copyWith(color: color),
            ),
          ),
        );

        // Apply circular border radius for icon buttons
        if (widget.iconOnly) {
          result = result.copyWith(
            decoration: result.decoration.map(
              (decoration) =>
                  decoration.copyWith(borderRadius: BorderRadius.circular(999)),
            ),
          );
        }

        return result;
      };
    } else {
      fStyle = switch (widget.style) {
        ButtonStyle.primary => FButtonStyle.primary(),
        ButtonStyle.secondary => FButtonStyle.outline(),
        ButtonStyle.ghost => FButtonStyle.ghost(),
      };

      // Apply circular border radius for icon buttons
      if (widget.iconOnly) {
        fStyle = (baseStyle) {
          final unselectedStyle = switch (widget.style) {
            ButtonStyle.primary => context.theme.buttonStyles.primary,
            ButtonStyle.secondary => context.theme.buttonStyles.outline,
            ButtonStyle.ghost => context.theme.buttonStyles.ghost,
          };

          return unselectedStyle.copyWith(
            decoration: unselectedStyle.decoration.map(
              (decoration) =>
                  decoration.copyWith(borderRadius: BorderRadius.circular(999)),
            ),
          );
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
        if (widget.command.subtitle != null &&
            widget.command.subtitle!.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.command.title),
              Text(
                widget.command.subtitle!,
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
