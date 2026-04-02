import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FToasterStyleDelta buildToasterStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  final isLight = colourScheme.brightness == Brightness.light;
  const hue = 25.72;

  // Opaque background and contrasting foreground for destructive toasts
  final destructiveBg = RayOklch.fromComponents(
    isLight ? 0.95 : 0.2,
    isLight ? 0.05 : 0.05,
    hue,
  ).toColor();
  final destructiveFg = RayOklch.fromComponents(
    isLight ? 0.4 : 0.8,
    isLight ? 0.15 : 0.15,
    hue,
  ).toColor();
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
