import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FTextFieldStyle buildTextFieldStyle(
  FTextFieldStyle baseStyle,
  ColourSchemeData colourScheme,
) {
  // ignore: unused_result
  return baseStyle.copyWith(
    cursorColor: colourScheme.accent,
    contentTextStyle: baseStyle.contentTextStyle.map(
      (style) => style.copyWith(color: colourScheme.foreground),
    ),
  );
}
