import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FHeaderStyles buildHeaderStyles(
  FHeaderStyles baseStyles,
  FTypography typography,
  ColourSchemeData colourScheme,
) {
  // ignore: unused_result
  return baseStyles.copyWith(
    // ignore: unused_result
    rootStyle: baseStyles.rootStyle.copyWith(
      titleTextStyle: typography.base.copyWith(
        color: colourScheme.muted,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
      actionSpacing: 0,
    ),
  );
}
