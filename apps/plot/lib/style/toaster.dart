import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FToasterStyle buildToasterStyle(
  FToasterStyle baseStyle,
  ColourSchemeData colourScheme,
  BorderRadius borderRadius,
  FTypography typography,
  PlotIconSizes iconSizes,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    // ignore: unused_result
    toastStyle: baseStyle.toastStyle.copyWith(
      decoration: BoxDecoration(
        border: Border.all(color: colourScheme.border),
        borderRadius: borderRadius,
        color: colourScheme.accentBackground,
      ),
      iconStyle: IconThemeData(color: colourScheme.accent, size: iconSizes.lg),
      titleTextStyle: typography.sm.copyWith(
        color: colourScheme.accent,
        fontWeight: FontWeight.w500,
      ),
      descriptionTextStyle: typography.sm.copyWith(
        color: colourScheme.accent,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}
