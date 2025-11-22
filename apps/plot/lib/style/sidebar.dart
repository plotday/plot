import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/layout.dart';

FSidebarStyle buildSidebarStyle(
  FSidebarStyle baseStyle,
  FTypography typography,
  ColourSchemeData colourScheme,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    groupStyle: (groupStyle) => groupStyle.copyWith(
      childrenPadding: EdgeInsets.zero,
      padding: EdgeInsets.only(bottom: 16),
      headerSpacing: 0,
      labelStyle: typography.sm.copyWith(
        color: colourScheme.foreground.withValues(alpha: 0.6),
        fontWeight: FontWeight.w600,
      ),
      actionStyle: groupStyle.actionStyle.map(
        (iconTheme) => iconTheme.copyWith(size: 12),
      ),
      itemStyle: (itemStyle) => itemStyle.copyWith(
        borderRadius: BorderRadius.zero,
        padding: widgetPaddingSm,
        textStyle: itemStyle.textStyle.map(
          (textStyle) => typography.base,
        ),
      ),
    ),
  );
}
