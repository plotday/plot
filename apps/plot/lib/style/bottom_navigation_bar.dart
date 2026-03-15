import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FBottomNavigationBarStyleDelta buildBottomNavigationBarStyleDelta(
  FBottomNavigationBarStyle baseStyle,
  ColourSchemeData colourScheme,
) {
  final colorScheme = colourScheme.toFColorScheme();
  final disabledForeground = colorScheme.disable(colourScheme.foreground);
  final baseTextStyle = baseStyle.itemStyle.textStyle.resolve({});

  return FBottomNavigationBarStyleDelta.delta(
    itemStyle: FBottomNavigationBarItemStyleDelta.delta(
      iconStyle: FVariants(
        IconThemeData(color: disabledForeground, size: 24),
        variants: {
          [FTappableVariantConstraint.selected]:
              IconThemeData(color: colourScheme.accent, size: 24),
        },
      ),
      textStyle: FVariants(
        baseTextStyle.copyWith(color: disabledForeground, fontSize: 10),
        variants: {
          [FTappableVariantConstraint.selected]:
              baseTextStyle.copyWith(color: colourScheme.accent, fontSize: 10),
        },
      ),
    ),
  );
}
