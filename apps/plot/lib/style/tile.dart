import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

FTileStyle buildTileStyle(FTileStyle baseStyle, FColors colors) {
  // ignore: unused_result
  return baseStyle.copyWith(
    backgroundColor: FWidgetStateMap({
      WidgetState.selected | WidgetState.hovered | WidgetState.pressed:
          colors.primaryForeground,
      WidgetState.any: const Color(0x00000000),
    }),
  );
}
