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
  final destructiveColor = RayOklch.fromComponents(
    colourScheme.brightness == Brightness.light ? 0.2 : 0.65,
    colourScheme.brightness == Brightness.light ? 0.8 : 0.15,
    25.72,
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
              color: destructiveColor.withValues(alpha: 0.1),
              borderRadius: borderRadius.md,
              border: Border.all(
                color: destructiveColor.withValues(alpha: 0.3),
              ),
            ),
          ),
          iconStyle: IconThemeDataDelta.value(
            IconThemeData(color: destructiveColor, size: iconSizes.lg),
          ),
          titleTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: destructiveColor,
              fontWeight: FontWeight.w500,
            ),
          ),
          descriptionTextStyle: TextStyleDelta.value(
            typography.sm.copyWith(
              color: destructiveColor,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    ]),
  );
}
