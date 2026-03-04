import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';

FButtonStyles buildButtonStyles(
  FButtonStyles baseStyles,
  ColourSchemeData colourScheme,
  BorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  return baseStyles.copyWith(
    // ignore: unused_result
    primary: baseStyles.primary.copyWith(
      // ignore: unused_result
      tappableStyle: (t) => t.copyWith(motion: (_) => FTappableMotion.none),
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withChroma(0)
              .withLightness(colourScheme.brightness == .light ? 0.95 : 0.27)
              .toColor(),
          border: Border.all(
            color: colourScheme.colours.accent
                .withChroma(0)
                .withLightness(colourScheme.brightness == .light ? 0.85 : 0.40)
                .toColor(),
          ),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withLightness(colourScheme.brightness == .light ? 0.90 : 0.30)
              .withChroma(colourScheme.brightness == .light ? 0.06 : 0.05)
              .toColor(),
          border: Border.all(
            color: colourScheme.colours.accent.withOpacity(0.5).toColor(),
          ),
        ),
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withLightness(colourScheme.brightness == .light ? 0.94 : 0.26)
              .withChroma(colourScheme.brightness == .light ? 0.04 : 0.03)
              .toColor(),
          border: Border.all(
            color: colourScheme.colours.accent.withOpacity(0.35).toColor(),
          ),
        ),
      }),
      // ignore: unused_result
      contentStyle: baseStyles.primary.contentStyle.copyWith(
        padding: PlotSpacing.fallback.padding,
        textStyle: FWidgetStateMap({
          WidgetState.disabled: typography.base.copyWith(
            color: colourScheme.colours.accent
                .withChroma(0)
                .withLightness(0.50)
                .toColor(),
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.hovered | WidgetState.pressed: typography.base.copyWith(
            color: colourScheme.colours.accent
                .withLightness(
                  colourScheme.brightness == .light
                      ? 0.35
                      : colourScheme.colours.accent.lightness,
                )
                .toColor(),
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.any: typography.base.copyWith(
            color: colourScheme.accent,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        }),
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.colours.accent
                .withChroma(0)
                .withLightness(0.50)
                .toColor(),
            size: iconSizes.base,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.colours.accent
                .withLightness(
                  colourScheme.brightness == .light
                      ? 0.35
                      : colourScheme.colours.accent.lightness,
                )
                .toColor(),
            size: iconSizes.base,
          ),
          WidgetState.any: IconThemeData(
            color: colourScheme.accent,
            size: iconSizes.base,
          ),
        }),
      ),
      // ignore: unused_result
      iconContentStyle: baseStyles.primary.iconContentStyle.copyWith(
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.colours.accent
                .withChroma(0)
                .withLightness(0.50)
                .toColor(),
            size: iconSizes.lg,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.colours.accent
                .withLightness(
                  colourScheme.brightness == .light
                      ? 0.35
                      : colourScheme.colours.accent.lightness,
                )
                .toColor(),
            size: iconSizes.lg,
          ),
          WidgetState.any: IconThemeData(
            color: colourScheme.accent,
            size: iconSizes.lg,
          ),
        }),
      ),
    ),
    // ignore: unused_result
    secondary: baseStyles.outline.copyWith(
      // ignore: unused_result
      tappableStyle: (t) => t.copyWith(motion: (_) => FTappableMotion.none),
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(color: colourScheme.border.withValues(alpha: 0.5)),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(color: colourScheme.border),
          color: colourScheme.brightness == Brightness.light
              ? colourScheme.colours.background.withLightness(1).toColor()
              : colourScheme.highlight,
        ),
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(color: colourScheme.border),
        ),
      }),
      // ignore: unused_result
      contentStyle: baseStyles.outline.contentStyle.copyWith(
        padding: PlotSpacing.fallback.padding,
        textStyle: FWidgetStateMap({
          WidgetState.disabled: typography.base.copyWith(
            color: colourScheme.veryMuted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.hovered | WidgetState.pressed: typography.base.copyWith(
            color: colourScheme.colours.muted
                .withLightness(colourScheme.brightness == .light ? 0.40 : 0.73)
                .toColor(),
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.any: typography.base.copyWith(
            color: colourScheme.muted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        }),
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.veryMuted,
            size: iconSizes.base,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.colours.muted
                .withLightness(colourScheme.brightness == .light ? 0.40 : 0.73)
                .toColor(),
            size: iconSizes.base,
          ),
          WidgetState.any: IconThemeData(
            color: colourScheme.muted,
            size: iconSizes.base,
          ),
        }),
      ),
    ),
    // ignore: unused_result
    outline: baseStyles.outline.copyWith(
      // ignore: unused_result
      tappableStyle: (t) => t.copyWith(motion: (_) => FTappableMotion.none),
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: colourScheme.colours.muted.withOpacity(0.4).toColor(),
            width: 1,
          ),
          color: colourScheme.colours.highlight
              .withLightness(colourScheme.brightness == .light ? 0.95 : 0.52)
              .toColor(),
        ),
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: colourScheme.colours.muted.withOpacity(0.4).toColor(),
            width: 1,
          ),
          color: colourScheme.colours.highlight
              .withLightness(colourScheme.brightness == .light ? 0.90 : 0.48)
              .toColor(),
        ),
      }),
    ),
    // ignore: unused_result
    ghost: baseStyles.ghost.copyWith(
      // ignore: unused_result
      tappableStyle: (t) => t.copyWith(motion: (_) => FTappableMotion.none),
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: Color(0x00000000), // Transparent border
            width: 2,
          ),
        ),
      }),
      // ignore: unused_result
      contentStyle: baseStyles.ghost.contentStyle.copyWith(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        spacing: 6,
        textStyle: FWidgetStateMap({
          WidgetState.disabled: typography.base.copyWith(
            color: colourScheme.muted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.hovered | WidgetState.pressed: typography.base.copyWith(
            color: colourScheme.foreground,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.any: typography.base.copyWith(
            color: colourScheme.muted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        }),
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.muted.withValues(alpha: 0.5),
            size: iconSizes.base,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.foreground,
            size: iconSizes.base,
          ),
          WidgetState.any: IconThemeData(
            color: colourScheme.muted,
            size: iconSizes.base,
          ),
        }),
      ),
      // ignore: unused_result
      iconContentStyle: baseStyles.ghost.iconContentStyle.copyWith(
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.muted.withValues(alpha: 0.5),
            size: iconSizes.lg,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.foreground,
            size: iconSizes.lg,
          ),
          WidgetState.any: IconThemeData(
            color: colourScheme.muted,
            size: iconSizes.lg,
          ),
        }),
      ),
    ),
  );
}
