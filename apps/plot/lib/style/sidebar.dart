import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

FSidebarStyle buildSidebarStyle(
  FSidebarStyle baseStyle,
  FTypography typography,
  ColourSchemeData colourScheme,
  PlotIconSizes iconSizes,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    groupStyle: (groupStyle) => groupStyle.copyWith(
      childrenPadding: EdgeInsets.zero,
      padding: EdgeInsets.only(bottom: 20),
      headerSpacing: 4,
      labelStyle: typography.sm.copyWith(
        color: colourScheme.foreground.withValues(alpha: 0.5),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
      actionStyle: groupStyle.actionStyle.map(
        (iconTheme) => iconTheme.copyWith(size: iconSizes.xs),
      ),
      itemStyle: (itemStyle) => itemStyle.copyWith(
        borderRadius: BorderRadius.circular(6),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: itemStyle.textStyle.map(
          (textStyle) => typography.base,
        ),
      ),
    ),
  );
}
