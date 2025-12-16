import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FTooltipStyle buildTooltipStyle(
  FTooltipStyle baseStyle,
  ColourSchemeData colourScheme,
  BorderRadius borderRadius,
  FTypography typography,
) {
  return baseStyle.copyWith(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  );
}
