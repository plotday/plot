import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FToasterStyleDelta buildToasterStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  return FToasterStyleDelta.delta(
    toastStyles: FVariantsDelta.delta([
      FVariantOperation.all(
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
    ]),
  );
}
