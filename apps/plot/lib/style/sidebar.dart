import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FSidebarStyleDelta buildSidebarStyleDelta(
  FTypography typography,
  ColourSchemeData colourScheme,
  PlotIconSizes iconSizes,
) {
  return FSidebarStyleDelta.delta(
    groupStyle: FSidebarGroupStyleDelta.delta(
      childrenPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
      padding: EdgeInsetsDelta.value(EdgeInsets.only(bottom: 20)),
      headerSpacing: 4,
      labelStyle: TextStyleDelta.value(
        typography.sm.copyWith(
          color: colourScheme.foreground.withValues(alpha: 0.5),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
      actionStyle: FVariantsDelta.delta([
        FVariantOperation.all(
          IconThemeDataDelta.delta(size: iconSizes.xs),
        ),
      ]),
      itemStyle: FSidebarItemStyleDelta.delta(
        borderRadius: BorderRadius.circular(6),
        padding: EdgeInsetsGeometryDelta.value(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        textStyle: FVariants<FTappableVariantConstraint, FTappableVariant,
            TextStyle, TextStyleDelta>.all(typography.md),
      ),
    ),
  );
}
