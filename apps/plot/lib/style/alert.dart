import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FVariantsDelta<FAlertVariantConstraint, FAlertVariant, FAlertStyle,
    FAlertStyleDelta> buildAlertStylesDelta(
  ColourSchemeData colourScheme,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  // Create destructive color using the same formula as toFColorScheme
  final destructiveColor = RayOklch.fromComponents(
    colourScheme.brightness == Brightness.light ? 0.2 : 0.65,
    colourScheme.brightness == Brightness.light ? 0.8 : 0.15,
    25.72,
  ).toColor();

  return FVariantsDelta.delta([
    FVariantOperation.exact(
      {FAlertVariantConstraint.primary},
      FAlertStyleDelta.delta(
        decoration: DecorationDelta.value(
          BoxDecoration(
            color: colourScheme.accentBackground.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(borderRadiusMd),
            border: Border.all(
              color: colourScheme.accent.withValues(alpha: 0.2),
            ),
          ),
        ),
        iconStyle: IconThemeDataDelta.value(
          IconThemeData(color: colourScheme.accent, size: iconSizes.lg),
        ),
        titleTextStyle: TextStyleDelta.value(
          typography.md.copyWith(
            color: colourScheme.accent,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitleTextStyle: TextStyleDelta.value(
          typography.sm.copyWith(color: colourScheme.accent),
        ),
      ),
    ),
    FVariantOperation.exact(
      {FAlertVariantConstraint.destructive},
      FAlertStyleDelta.delta(
        decoration: DecorationDelta.value(
          BoxDecoration(
            color: destructiveColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(borderRadiusMd),
            border: Border.all(
              color: destructiveColor.withValues(alpha: 0.3),
            ),
          ),
        ),
        iconStyle: IconThemeDataDelta.value(
          IconThemeData(color: destructiveColor, size: iconSizes.lg),
        ),
        titleTextStyle: TextStyleDelta.value(
          typography.md.copyWith(
            color: destructiveColor,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitleTextStyle: TextStyleDelta.value(
          typography.sm.copyWith(color: destructiveColor),
        ),
      ),
    ),
  ]);
}
