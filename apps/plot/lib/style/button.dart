import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_icon_sizes.dart';

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
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withChroma(0)
              .withLightness(colourScheme.brightness == .light ? 0.95 : 0.27)
              .toColor(),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withLightness(colourScheme.brightness == .light ? 0.64 : 0.33)
              .toColor(),
        ),
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          color: colourScheme.colours.accent
              .withLightness(colourScheme.brightness == .light ? 0.68 : 0.3)
              .toColor(),
        ),
      }),
      // ignore: unused_result
      contentStyle: baseStyles.primary.contentStyle.copyWith(
        padding: widgetPadding,
        textStyle: FWidgetStateMap({
          WidgetState.disabled: typography.base.copyWith(
            color: colourScheme.colours.accent
                .withChroma(0)
                .withLightness(0.50)
                .toColor(),
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.any: typography.base.copyWith(
            color: Color(0xFFFFFFFF),
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
          WidgetState.any: IconThemeData(color: Color(0xFFFFFFFF), size: iconSizes.base),
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
          WidgetState.any: IconThemeData(color: Color(0xFFFFFFFF), size: iconSizes.lg),
        }),
      ),
    ),
    // ignore: unused_result
    secondary: baseStyles.outline.copyWith(
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          borderRadius: borderRadius,
          border: colourScheme.brightness == .light
              ? Border.all(
                  color: colourScheme.colours.highlight
                      .withLightness(0.86)
                      .withOpacity(0.5)
                      .toColor(),
                  width: 1,
                )
              : null,
          color: colourScheme.colours.highlight.toColor(),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          borderRadius: borderRadius,
          border: colourScheme.brightness == .light
              ? Border.all(
                  color: colourScheme.colours.highlight
                      .withLightness(0.86)
                      .toColor(),
                  width: 1,
                )
              : null,
          color: colourScheme.colours.accentBackground
              .withChroma(colourScheme.brightness == .light ? 0.05 : 0.2)
              .withLightness(colourScheme.brightness == .light ? 0.97 : 0.35)
              .toColor(),
        ),
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          border: colourScheme.brightness == .light
              ? Border.all(
                  color: colourScheme.colours.highlight
                      .withLightness(0.86)
                      .toColor(),
                  width: 1,
                )
              : null,
          color: colourScheme.colours.highlight.toColor(),
        ),
      }),
      // ignore: unused_result
      contentStyle: baseStyles.outline.contentStyle.copyWith(
        padding: widgetPadding,
        textStyle: FWidgetStateMap({
          WidgetState.disabled: typography.base.copyWith(
            color: colourScheme.muted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
          WidgetState.any: typography.base.copyWith(
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        }),
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.muted,
            size: iconSizes.base,
          ),
          WidgetState.any: IconThemeData(size: iconSizes.base),
        }),
      ),
    ),
    // ignore: unused_result
    outline: baseStyles.outline.copyWith(
      // ignore: unused_result
      decoration: FWidgetStateMap({
        WidgetState.any: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: colourScheme.colours.muted.withOpacity(0.4).toColor(),
            width: 1,
          ),
          color: colourScheme.colours.highlight
              .withLightness(colourScheme.brightness == .light ? 0.78 : 0.48)
              .toColor(),
        ),
      }),
    ),
    // ignore: unused_result
    ghost: baseStyles.ghost.copyWith(
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
            color: colourScheme.muted,
            size: iconSizes.base,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.foreground,
            size: iconSizes.base,
          ),
          WidgetState.any: IconThemeData(color: colourScheme.muted, size: iconSizes.base),
        }),
      ),
      // ignore: unused_result
      iconContentStyle: baseStyles.ghost.iconContentStyle.copyWith(
        iconStyle: FWidgetStateMap({
          WidgetState.disabled: IconThemeData(
            color: colourScheme.muted,
            size: iconSizes.lg,
          ),
          WidgetState.hovered | WidgetState.pressed: IconThemeData(
            color: colourScheme.foreground,
            size: iconSizes.lg,
          ),
          WidgetState.any: IconThemeData(color: colourScheme.muted, size: iconSizes.lg),
        }),
      ),
    ),
  );
}
