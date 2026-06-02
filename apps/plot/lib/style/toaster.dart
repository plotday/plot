import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

const _destructiveToastHue = 25.72;

/// Foreground (text/icon) color for destructive toasts.
///
/// Destructive toasts use a pale background (see [buildToasterStyleDelta]), so
/// the foreground is a dark red in light mode and a light red in dark mode —
/// NOT forui's default `destructiveForeground` (near-white), which assumes a
/// solid red background and is illegible on the pale surface. Any custom
/// content placed inside a destructive toast (e.g. the copy button) must use
/// this color to stay legible.
Color destructiveToastForeground(ColourSchemeData colourScheme) {
  final isLight = colourScheme.brightness == Brightness.light;
  return RayOklch.fromComponents(
    isLight ? 0.4 : 0.8,
    0.15,
    _destructiveToastHue,
  ).toColor();
}

FToasterStyleDelta buildToasterStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  final isLight = colourScheme.brightness == Brightness.light;
  const hue = _destructiveToastHue;

  // Opaque background and contrasting foreground for destructive toasts
  final destructiveBg = RayOklch.fromComponents(
    isLight ? 0.95 : 0.2,
    isLight ? 0.05 : 0.05,
    hue,
  ).toColor();
  final destructiveFg = destructiveToastForeground(colourScheme);
  final destructiveBorder = RayOklch.fromComponents(
    isLight ? 0.8 : 0.35,
    isLight ? 0.1 : 0.1,
    hue,
  ).toColor();

  return FToasterStyleDelta.delta(
    toastStyles: FVariantsDelta.delta([
      FVariantOperation.exact(
        {FToastVariantConstraint.primary},
        FToastStyleDelta.delta(
          decoration: DecorationDelta.value(
            BoxDecoration(
              border: Border.all(color: colourScheme.border),
              borderRadius: borderRadius.md,
              color: colourScheme.accentBackground,
            ),
          ),
          iconStyle: IconThemeDataDelta.value(
            IconThemeData(color: colourScheme.accent, size: iconSizes.lg),
          ),
          titleTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: colourScheme.accent,
              fontWeight: FontWeight.w500,
            ),
          ),
          descriptionTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: colourScheme.accent,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
      FVariantOperation.exact(
        {FToastVariantConstraint.destructive},
        FToastStyleDelta.delta(
          decoration: DecorationDelta.value(
            BoxDecoration(
              color: destructiveBg,
              borderRadius: borderRadius.md,
              border: Border.all(color: destructiveBorder),
            ),
          ),
          iconStyle: IconThemeDataDelta.value(
            IconThemeData(color: destructiveFg, size: iconSizes.lg),
          ),
          titleTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: destructiveFg,
              fontWeight: FontWeight.w500,
            ),
          ),
          descriptionTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: destructiveFg,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    ]),
  );
}
