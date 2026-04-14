import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';

FVariantsDelta<FButtonVariantConstraint, FButtonVariant, FButtonSizeStyles,
    FButtonSizesDelta> buildButtonStylesDelta(
  FButtonStyles baseStyles,
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  return FVariantsDelta.delta([
    // Primary button
    FVariantOperation.exact(
      {FButtonVariantConstraint.primary},
      FButtonSizesDelta.delta([
        FVariantOperation.all(
          _buildPrimaryStyleDelta(colourScheme, borderRadius, typography, iconSizes),
        ),
      ]),
    ),
    // Secondary button (based on outline style)
    FVariantOperation.exact(
      {FButtonVariantConstraint.secondary},
      FButtonSizesDelta.delta([
        FVariantOperation.all(
          _buildSecondaryStyleDelta(colourScheme, borderRadius, typography, iconSizes),
        ),
      ]),
    ),
    // Outline button
    FVariantOperation.exact(
      {FButtonVariantConstraint.outline},
      FButtonSizesDelta.delta([
        FVariantOperation.all(
          _buildOutlineStyleDelta(colourScheme, borderRadius),
        ),
      ]),
    ),
    // Ghost button
    FVariantOperation.exact(
      {FButtonVariantConstraint.ghost},
      FButtonSizesDelta.delta([
        FVariantOperation.all(
          _buildGhostStyleDelta(colourScheme, borderRadius, typography, iconSizes),
        ),
      ]),
    ),
  ]);
}

// Helper to create a tappable decoration FVariants with base, disabled,
// hovered, and pressed states.
FVariants<FTappableVariantConstraint, FTappableVariant, Decoration,
    DecorationDelta> _decorationVariants({
  required Decoration base,
  Decoration? disabled,
  Decoration? hovered,
  Decoration? pressed,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant, Decoration,
      DecorationDelta>(
    base,
    variants: {
      if (disabled != null)
        [FTappableVariantConstraint.disabled]: disabled,
      if (hovered != null)
        [FTappableVariantConstraint.hovered]: hovered,
      if (pressed != null)
        [FTappableVariantConstraint.pressed]: pressed,
    },
  );
}

// Helper to create tappable text style FVariants.
FVariants<FTappableVariantConstraint, FTappableVariant, TextStyle,
    TextStyleDelta> _textStyleVariants({
  required TextStyle base,
  TextStyle? disabled,
  TextStyle? hovered,
  TextStyle? pressed,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant, TextStyle,
      TextStyleDelta>(
    base,
    variants: {
      if (disabled != null)
        [FTappableVariantConstraint.disabled]: disabled,
      if (hovered != null)
        [FTappableVariantConstraint.hovered]: hovered,
      if (pressed != null)
        [FTappableVariantConstraint.pressed]: pressed,
    },
  );
}

// Helper to create tappable icon theme FVariants.
FVariants<FTappableVariantConstraint, FTappableVariant, IconThemeData,
    IconThemeDataDelta> _iconVariants({
  required IconThemeData base,
  IconThemeData? disabled,
  IconThemeData? hovered,
  IconThemeData? pressed,
}) {
  return FVariants<FTappableVariantConstraint, FTappableVariant, IconThemeData,
      IconThemeDataDelta>(
    base,
    variants: {
      if (disabled != null)
        [FTappableVariantConstraint.disabled]: disabled,
      if (hovered != null)
        [FTappableVariantConstraint.hovered]: hovered,
      if (pressed != null)
        [FTappableVariantConstraint.pressed]: pressed,
    },
  );
}

FButtonStyleDelta _buildPrimaryStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  final disabledColor = colourScheme.colours.accent
      .withChroma(0)
      .withLightness(colourScheme.brightness == .light ? 0.95 : 0.27)
      .toColor();
  final disabledBorderColor = colourScheme.colours.accent
      .withChroma(0)
      .withLightness(colourScheme.brightness == .light ? 0.85 : 0.40)
      .toColor();
  final hoveredColor = colourScheme.colours.accent
      .withLightness(colourScheme.brightness == .light ? 0.90 : 0.30)
      .withChroma(colourScheme.brightness == .light ? 0.06 : 0.05)
      .toColor();
  final hoveredBorderColor =
      colourScheme.colours.accent.withOpacity(0.5).toColor();
  final baseColor = colourScheme.colours.accent
      .withLightness(colourScheme.brightness == .light ? 0.94 : 0.26)
      .withChroma(colourScheme.brightness == .light ? 0.04 : 0.03)
      .toColor();
  final baseBorderColor =
      colourScheme.colours.accent.withOpacity(0.35).toColor();

  final disabledFg = colourScheme.colours.accent
      .withChroma(0)
      .withLightness(0.50)
      .toColor();
  final hoveredFg = colourScheme.colours.accent
      .withLightness(
        colourScheme.brightness == .light
            ? 0.35
            : colourScheme.colours.accent.lightness,
      )
      .toColor();

  final hoveredDecoration = BoxDecoration(
    borderRadius: borderRadius.md,
    color: hoveredColor,
    border: Border.all(color: hoveredBorderColor),
  );

  return FButtonStyleDelta.delta(
    tappableStyle: FTappableStyleDelta.delta(motion: FTappableMotion.none),
    decoration: _decorationVariants(
      base: BoxDecoration(
        borderRadius: borderRadius.md,
        color: baseColor,
        border: Border.all(color: baseBorderColor),
      ),
      disabled: BoxDecoration(
        borderRadius: borderRadius.md,
        color: disabledColor,
        border: Border.all(color: disabledBorderColor),
      ),
      hovered: hoveredDecoration,
      pressed: hoveredDecoration,
    ),
    contentStyle: FButtonContentStyleDelta.delta(
      padding: EdgeInsetsGeometryDelta.value(PlotSpacing.fallback.padding),
      textStyle: _textStyleVariants(
        base: typography.md.copyWith(
          color: colourScheme.accent, fontWeight: FontWeight.w500, height: 1,
        ),
        disabled: typography.md.copyWith(
          color: disabledFg, fontWeight: FontWeight.w500, height: 1,
        ),
        hovered: typography.md.copyWith(
          color: hoveredFg, fontWeight: FontWeight.w500, height: 1,
        ),
        pressed: typography.md.copyWith(
          color: hoveredFg, fontWeight: FontWeight.w500, height: 1,
        ),
      ),
      iconStyle: _iconVariants(
        base: IconThemeData(color: colourScheme.accent, size: iconSizes.base),
        disabled: IconThemeData(color: disabledFg, size: iconSizes.base),
        hovered: IconThemeData(color: hoveredFg, size: iconSizes.base),
        pressed: IconThemeData(color: hoveredFg, size: iconSizes.base),
      ),
    ),
    iconContentStyle: FButtonIconContentStyleDelta.delta(
      iconStyle: _iconVariants(
        base: IconThemeData(color: colourScheme.accent, size: iconSizes.lg),
        disabled: IconThemeData(color: disabledFg, size: iconSizes.lg),
        hovered: IconThemeData(color: hoveredFg, size: iconSizes.lg),
        pressed: IconThemeData(color: hoveredFg, size: iconSizes.lg),
      ),
    ),
  );
}

FButtonStyleDelta _buildSecondaryStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  final hoveredBgColor = colourScheme.brightness == Brightness.light
      ? colourScheme.colours.background.withLightness(1).toColor()
      : colourScheme.highlight;
  final hoveredFg = colourScheme.colours.muted
      .withLightness(colourScheme.brightness == .light ? 0.40 : 0.73)
      .toColor();

  final hoveredDecoration = BoxDecoration(
    borderRadius: borderRadius.md,
    border: Border.all(color: colourScheme.border),
    color: hoveredBgColor,
  );

  return FButtonStyleDelta.delta(
    tappableStyle: FTappableStyleDelta.delta(motion: FTappableMotion.none),
    decoration: _decorationVariants(
      base: BoxDecoration(
        borderRadius: borderRadius.md,
        border: Border.all(color: colourScheme.border),
      ),
      disabled: BoxDecoration(
        borderRadius: borderRadius.md,
        border: Border.all(
          color: colourScheme.border.withValues(alpha: 0.5),
        ),
      ),
      hovered: hoveredDecoration,
      pressed: hoveredDecoration,
    ),
    contentStyle: FButtonContentStyleDelta.delta(
      padding: EdgeInsetsGeometryDelta.value(PlotSpacing.fallback.padding),
      textStyle: _textStyleVariants(
        base: typography.md.copyWith(
          color: colourScheme.muted, fontWeight: FontWeight.w500, height: 1,
        ),
        disabled: typography.md.copyWith(
          color: colourScheme.veryMuted, fontWeight: FontWeight.w500, height: 1,
        ),
        hovered: typography.md.copyWith(
          color: hoveredFg, fontWeight: FontWeight.w500, height: 1,
        ),
        pressed: typography.md.copyWith(
          color: hoveredFg, fontWeight: FontWeight.w500, height: 1,
        ),
      ),
      iconStyle: _iconVariants(
        base: IconThemeData(color: colourScheme.muted, size: iconSizes.base),
        disabled: IconThemeData(
          color: colourScheme.veryMuted, size: iconSizes.base,
        ),
        hovered: IconThemeData(color: hoveredFg, size: iconSizes.base),
        pressed: IconThemeData(color: hoveredFg, size: iconSizes.base),
      ),
    ),
  );
}

FButtonStyleDelta _buildOutlineStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
) {
  final mutedBorder =
      colourScheme.colours.muted.withOpacity(0.4).toColor();
  final baseHighlight = colourScheme.colours.highlight
      .withLightness(colourScheme.brightness == .light ? 0.90 : 0.48)
      .toColor();
  final hoveredHighlight = colourScheme.colours.highlight
      .withLightness(colourScheme.brightness == .light ? 0.95 : 0.52)
      .toColor();

  final hoveredDecoration = BoxDecoration(
    borderRadius: borderRadius.md,
    border: Border.all(color: mutedBorder, width: 1),
    color: hoveredHighlight,
  );

  return FButtonStyleDelta.delta(
    tappableStyle: FTappableStyleDelta.delta(motion: FTappableMotion.none),
    decoration: _decorationVariants(
      base: BoxDecoration(
        borderRadius: borderRadius.md,
        border: Border.all(color: mutedBorder, width: 1),
        color: baseHighlight,
      ),
      hovered: hoveredDecoration,
      pressed: hoveredDecoration,
    ),
  );
}

FButtonStyleDelta _buildGhostStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  final mobilePadding = EdgeInsets.all(isMobilePlatform() ? 14 : 10);
  final mobileIconPadding = EdgeInsets.all(isMobilePlatform() ? 14 : 7.5);

  return FButtonStyleDelta.delta(
    tappableStyle: FTappableStyleDelta.delta(motion: FTappableMotion.none),
    decoration: _decorationVariants(
      base: BoxDecoration(
        borderRadius: borderRadius.md,
        border: Border.all(color: const Color(0x00000000), width: 2),
      ),
    ),
    contentStyle: FButtonContentStyleDelta.delta(
      padding: EdgeInsetsGeometryDelta.value(mobilePadding),
      spacing: 6,
      textStyle: _textStyleVariants(
        base: typography.md.copyWith(
          color: colourScheme.veryMuted, fontWeight: FontWeight.w500, height: 1,
        ),
        disabled: typography.md.copyWith(
          color: colourScheme.veryMuted, fontWeight: FontWeight.w500, height: 1,
        ),
        hovered: typography.md.copyWith(
          color: colourScheme.foreground, fontWeight: FontWeight.w500, height: 1,
        ),
        pressed: typography.md.copyWith(
          color: colourScheme.foreground, fontWeight: FontWeight.w500, height: 1,
        ),
      ),
      iconStyle: _iconVariants(
        base: IconThemeData(color: colourScheme.veryMuted, size: iconSizes.base),
        disabled: IconThemeData(
          color: colourScheme.veryMuted.withValues(alpha: 0.5),
          size: iconSizes.base,
        ),
        hovered: IconThemeData(
          color: colourScheme.foreground, size: iconSizes.base,
        ),
        pressed: IconThemeData(
          color: colourScheme.foreground, size: iconSizes.base,
        ),
      ),
    ),
    iconContentStyle: FButtonIconContentStyleDelta.delta(
      padding: EdgeInsetsGeometryDelta.value(mobileIconPadding),
      iconStyle: _iconVariants(
        base: IconThemeData(color: colourScheme.veryMuted, size: iconSizes.lg),
        disabled: IconThemeData(
          color: colourScheme.veryMuted.withValues(alpha: 0.5),
          size: iconSizes.lg,
        ),
        hovered: IconThemeData(
          color: colourScheme.foreground, size: iconSizes.lg,
        ),
        pressed: IconThemeData(
          color: colourScheme.foreground, size: iconSizes.lg,
        ),
      ),
    ),
  );
}

/// Produces an [FButtonStyleDelta] for ghost [FButton]s that overrides the
/// text size, icon size, and/or colors while preserving hover/pressed color
/// variants.
///
/// Use this at call sites that need a smaller or recolored ghost button
/// without losing the base → hovered color transition. Pass the resulting
/// delta as [FButton]'s `style:`, then let [prefix] / `child` inherit colors
/// from the ambient [IconTheme] / [DefaultTextStyle] (i.e. don't set `color:`
/// on child [Text]/[Icon]).
///
/// - [textStyle]: base text style (e.g. `typography.sm`). `fontWeight: w500`
///   and `height: 1` are applied automatically to match the ghost defaults,
///   which keeps icon and text vertically centered.
/// - [iconSize]: icon size applied to prefix/suffix icons.
/// - [color] / [hoverColor]: override base and hovered colors. Default to
///   `plotColors.veryMuted` and `colors.foreground` (the ghost defaults).
FButtonStyleDelta ghostSizedStyleDelta(
  BuildContext context, {
  TextStyle? textStyle,
  double? iconSize,
  Color? color,
  Color? hoverColor,
}) {
  final base = (textStyle ?? context.theme.typography.md).copyWith(
    fontWeight: FontWeight.w500,
    height: 1,
  );
  final iconPx = iconSize ?? context.theme.iconSizes.base;
  final baseColor = color ?? context.theme.plotColors.veryMuted;
  final hoverC = hoverColor ?? context.theme.colors.foreground;

  return FButtonStyleDelta.delta(
    contentStyle: FButtonContentStyleDelta.delta(
      textStyle: _textStyleVariants(
        base: base.copyWith(color: baseColor),
        hovered: base.copyWith(color: hoverC),
        pressed: base.copyWith(color: hoverC),
      ),
      iconStyle: _iconVariants(
        base: IconThemeData(color: baseColor, size: iconPx),
        hovered: IconThemeData(color: hoverC, size: iconPx),
        pressed: IconThemeData(color: hoverC, size: iconPx),
      ),
    ),
  );
}
