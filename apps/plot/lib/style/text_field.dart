import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FTextFieldStyle buildTextFieldStyle(
  FTextFieldStyle baseStyle,
  ColourSchemeData colourScheme,
  BorderRadius borderRadius,
  double borderWidth,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    cursorColor: colourScheme.muted,
    fillColor: colourScheme.editableBackground,
    border: FWidgetStateMap({
      WidgetState.focused: OutlineInputBorder(
        borderSide: BorderSide(color: colourScheme.accent, width: borderWidth),
        borderRadius: borderRadius,
      ),
      WidgetState.any: OutlineInputBorder(
        borderSide: BorderSide(color: colourScheme.border, width: borderWidth),
        borderRadius: borderRadius,
      ),
    }),
    contentTextStyle: baseStyle.contentTextStyle.map(
      (style) => style.copyWith(color: colourScheme.foreground),
    ),
  );
}
