import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FTooltipStyleDelta buildTooltipStyleDelta(
  ColourSchemeData colourScheme,
  FTypography typography,
) {
  return FTooltipStyleDelta.delta(
    padding: EdgeInsetsDelta.value(
      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    ),
  );
}
