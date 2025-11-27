import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FBottomNavigationBarStyle buildBottomNavigationBarStyle(
  FBottomNavigationBarStyle baseStyle,
  ColourSchemeData colourScheme,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    // ignore: unused_result
    itemStyle: baseStyle.itemStyle.copyWith(
      iconStyle: FWidgetStateMap({
        WidgetState.selected: IconThemeData(
          color: colourScheme.accent, // Use accent color for selected state
          size: 24,
        ),
        WidgetState.any: IconThemeData(
          color: colourScheme.toFColorScheme()
              .disable(colourScheme.foreground),
          size: 24,
        ),
      }),
      textStyle: FWidgetStateMap({
        WidgetState.selected: baseStyle.itemStyle.textStyle
            .resolve({}).copyWith(
                  color: colourScheme.accent, // Use accent color for selected state
                  fontSize: 10,
                ),
        WidgetState.any: baseStyle.itemStyle.textStyle
            .resolve({}).copyWith(
                  color: colourScheme.toFColorScheme()
                      .disable(colourScheme.foreground),
                  fontSize: 10,
                ),
      }),
    ),
  );
}
