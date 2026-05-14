import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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
       hoverColor = null,
       forceHover = false,
       onLongPress = null;

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
       hoverColor = null,
       forceHover = false,
       onLongPress = null;

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
       hoverColor = null,
       forceHover = false,
       onLongPress = null;

  const Button.icon(
    this.command, {
    this.style = ButtonStyle.ghost,
    this.loading = false,
    this.enabled = true,
    this.selected = false,
    this.selectedColor,
    this.color,
    this.hoverColor,
    this.forceHover = false,
    this.onLongPress,
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
  /// Color override for non-selected hover state icon/text.
  final Color? hoverColor;
  final bool forceHover;
  final bool iconOnly;
  final bool expand;
  final Command command;
  /// Optional long-press callback (icon-only buttons).
  final VoidCallback? onLongPress;

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  bool _isHovered = false;

  FButtonVariant _variant() {
    return switch (widget.style) {
      ButtonStyle.primary => FButtonVariant.primary,
      ButtonStyle.secondary => FButtonVariant.secondary,
      ButtonStyle.ghost => FButtonVariant.ghost,
    };
  }

  @override
  Widget build(BuildContext context) {
    FButtonVariant variant;
    FButtonStyleDelta styleDelta;

    if (widget.selected) {
      // For selected state, we build a complete FButtonStyle and pass it as the delta
      // (FButtonStyle implements FButtonStyleDelta and returns itself)
      variant = _variant();
      styleDelta = _buildSelectedStyle(context);
    } else {
      variant = _variant();

      if (widget.iconOnly) {
        styleDelta = _buildIconOnlyStyle(context);
      } else {
        styleDelta = const FButtonStyleDelta.context();
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

          // Absorb horizontal padding into the icon SizedBox so
          // variable-width FontAwesome icons stay centred without
          // changing the overall button size.
          final iconSize = context.theme.iconSizes.base;
          final iconPadH = (switch (widget.style) {
            ButtonStyle.primary => context.theme.buttonStyles.primary,
            ButtonStyle.secondary => context.theme.buttonStyles.secondary,
            ButtonStyle.ghost => context.theme.buttonStyles.ghost,
          }).md.iconContentStyle.padding.resolve(TextDirection.ltr).left;

          Widget? iconChild;
          if (customIcon != null) {
            iconChild = customIcon;
          } else if (icon != null) {
            iconChild = FaIcon(icon, size: iconSize);
          }

          return widget.iconOnly
              ? FButton.icon(
                  variant: variant,
                  style: styleDelta,
                  onPress: onPress,
                  child: iconChild != null
                      ? SizedBox(
                          width: iconSize + iconPadH * 2,
                          height: iconSize,
                          child: Center(child: iconChild),
                        )
                      : (widget.command.buildBody(context) ??
                            Text(
                              widget.command.title,
                              style: context.theme.typography.md.copyWith(
                                height: 1,
                                textBaseline: TextBaseline.ideographic,
                              ),
                            )),
                )
              : FButton(
                  variant: variant,
                  style: styleDelta,
                  onPress: onPress,
                  prefix: icon != null
                      ? Icon(icon, size: context.theme.iconSizes.base)
                      : null,
                  child: widget.expand
                      ? Flexible(
                          child: Text(
                            widget.command.title,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        )
                      : Text(
                          widget.command.title,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                );
        },
      ),
    );

    if (widget.onLongPress != null) {
      return _wrapButton(
        GestureDetector(
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onLongPress,
          child: button,
        ),
      );
    }

    return _wrapButton(button);
  }

  /// Build style for selected state. Returns a full FButtonStyle which
  /// implements FButtonStyleDelta (ignoring the base and returning itself).
  FButtonStyleDelta _buildSelectedStyle(BuildContext context) {
    // Ghost selected: keep ghost decoration, just color the text/icon
    // Primary/secondary selected: use primary style (tint background)
    final sizeStyles = widget.style == ButtonStyle.ghost
        ? context.theme.buttonStyles.ghost
        : context.theme.buttonStyles.primary;
    var style = sizeStyles.md;

    if (widget.iconOnly) {
      final iconPadV = style.iconContentStyle.padding.resolve(TextDirection.ltr).top;
      style = style.copyWith(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(999)),
          ),
        ]),
        // ignore: unused_result
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(EdgeInsets.symmetric(vertical: iconPadV)),
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
        contentStyle: FButtonContentStyleDelta.delta(
          textStyle: _textStyleVariants(
            base: style.contentStyle.textStyle
                .resolve({}).copyWith(color: color),
            hovered: style.contentStyle.textStyle
                .resolve({FTappableVariant.hovered}).copyWith(color: hoverColor),
          ),
          iconStyle: _iconVariants(
            base: style.contentStyle.iconStyle
                .resolve({}).copyWith(color: color),
            hovered: style.contentStyle.iconStyle
                .resolve({FTappableVariant.hovered}).copyWith(color: hoverColor),
          ),
        ),
        // ignore: unused_result
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          iconStyle: _iconVariants(
            base: style.iconContentStyle.iconStyle
                .resolve({}).copyWith(color: color),
            hovered: style.iconContentStyle.iconStyle
                .resolve({FTappableVariant.hovered}).copyWith(color: hoverColor),
          ),
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

      final baseRadius = widget.iconOnly
          ? BorderRadius.circular(999)
          : (style.decoration.resolve({}) as BoxDecoration).borderRadius as BorderRadius?;

      style = style.copyWith(
        // ignore: unused_result
        decoration: _decorationVariants(
          base: BoxDecoration(
            borderRadius: baseRadius,
            color: bgColor,
            border: Border.all(color: borderColor),
          ),
          hovered: BoxDecoration(
            borderRadius: baseRadius,
            color: hoverBgColor,
            border: Border.all(color: hoverBorderColor),
          ),
        ),
        // ignore: unused_result
        contentStyle: FButtonContentStyleDelta.delta(
          textStyle: _textStyleVariants(
            base: style.contentStyle.textStyle
                .resolve({}).copyWith(color: fgColor),
          ),
          iconStyle: _iconVariants(
            base: style.contentStyle.iconStyle
                .resolve({}).copyWith(color: fgColor),
          ),
        ),
        // ignore: unused_result
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          iconStyle: _iconVariants(
            base: style.iconContentStyle.iconStyle
                .resolve({}).copyWith(color: fgColor),
          ),
        ),
      );
    }

    return style;
  }

  /// Build style delta for non-selected icon-only buttons.
  ///
  /// Resting icon color defaults to `plotColors.muted` so all icon buttons
  /// share the same dim tone (matching `FColors.mutedForeground`). Hover
  /// lifts to `colour.foreground` for a dramatic brightness jump. Callers
  /// can override either with `color:` / `hoverColor:`.
  ///
  /// Primary buttons opt out: the theme already paints the icon in the
  /// accent color over a pale tinted background, and muting it makes the
  /// button read as disabled.
  FButtonStyleDelta _buildIconOnlyStyle(BuildContext context) {
    final sizeStyles = switch (widget.style) {
      ButtonStyle.primary => context.theme.buttonStyles.primary,
      ButtonStyle.secondary => context.theme.buttonStyles.secondary,
      ButtonStyle.ghost => context.theme.buttonStyles.ghost,
    };
    final iconPadV = sizeStyles.md.iconContentStyle.padding.resolve(TextDirection.ltr).top;
    final isPrimary = widget.style == ButtonStyle.primary;

    var style = sizeStyles.md.copyWith(
      decoration: FVariantsDelta.delta([
        FVariantOperation.all(
          DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(999)),
        ),
      ]),
    );

    if (isPrimary && widget.color == null) {
      // Keep the primary theme's icon coloring; only patch padding.
      return style.copyWith(
        // ignore: unused_result
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(vertical: iconPadV),
          ),
        ),
      );
    }

    final restingColor = widget.color ?? context.colour.muted;
    final hoverColor = widget.hoverColor ?? context.colour.foreground;
    final iconStyle = style.iconContentStyle.iconStyle;

    return style.copyWith(
      // ignore: unused_result
      iconContentStyle: FButtonIconContentStyleDelta.delta(
        padding: EdgeInsetsGeometryDelta.value(
          EdgeInsets.symmetric(vertical: iconPadV),
        ),
        iconStyle: _iconVariants(
          base: iconStyle.resolve({}).copyWith(color: restingColor),
          hovered: iconStyle
              .resolve({FTappableVariant.hovered})
              .copyWith(color: hoverColor),
        ),
      ),
    );
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
                  style: context.theme.typography.xs.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
              if (shortcutText.isNotEmpty)
                Text(
                  shortcutText,
                  style: context.theme.typography.xs.copyWith(
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

// Helpers to create tappable FVariants for decoration, text, and icon styles.
// FVariants implements FVariantsDelta, so these can be passed directly to copyWith.

FVariants<FTappableVariantConstraint, FTappableVariant, Decoration,
    DecorationDelta> _decorationVariants({
  required Decoration base,
  Decoration? hovered,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant, Decoration,
      DecorationDelta>(
    base,
    variants: {
      if (hovered != null) ...<List<FTappableVariantConstraint>, Decoration>{
        [FTappableVariantConstraint.hovered]: hovered,
        [FTappableVariantConstraint.pressed]: hovered,
      },
    },
  );
}

FVariants<FTappableVariantConstraint, FTappableVariant, TextStyle,
    TextStyleDelta> _textStyleVariants({
  required TextStyle base,
  TextStyle? hovered,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant, TextStyle,
      TextStyleDelta>(
    base,
    variants: {
      if (hovered != null) ...<List<FTappableVariantConstraint>, TextStyle>{
        [FTappableVariantConstraint.hovered]: hovered,
        [FTappableVariantConstraint.pressed]: hovered,
      },
    },
  );
}

FVariants<FTappableVariantConstraint, FTappableVariant, IconThemeData,
    IconThemeDataDelta> _iconVariants({
  required IconThemeData base,
  IconThemeData? hovered,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant,
      IconThemeData, IconThemeDataDelta>(
    base,
    variants: {
      if (hovered != null) ...<List<FTappableVariantConstraint>, IconThemeData>{
        [FTappableVariantConstraint.hovered]: hovered,
        [FTappableVariantConstraint.pressed]: hovered,
      },
    },
  );
}
