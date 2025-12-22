import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';

FAlertStyles buildAlertStyles(
  FAlertStyles baseStyles,
  ColourSchemeData colourScheme,
  BorderRadius borderRadius,
  FTypography typography,
) {
  // Create destructive color using the same formula as toFColorScheme
  final destructiveColor = RayOklch.fromComponents(
    colourScheme.brightness == Brightness.light ? 0.2 : 0.65,
    colourScheme.brightness == Brightness.light ? 0.8 : 0.15,
    25.72,
  ).toColor();

  return baseStyles.copyWith(
    // ignore: unused_result
    primary: baseStyles.primary.copyWith(
      decoration: BoxDecoration(
        color: colourScheme.accentBackground.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colourScheme.accent.withValues(alpha: 0.2)),
      ),
      iconStyle: IconThemeData(color: colourScheme.accent, size: 20),
      titleTextStyle: typography.base.copyWith(
        color: colourScheme.accent,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: typography.sm.copyWith(color: colourScheme.accent),
    ),
    // ignore: unused_result
    destructive: baseStyles.destructive.copyWith(
      decoration: BoxDecoration(
        color: destructiveColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: destructiveColor.withValues(alpha: 0.3)),
      ),
      iconStyle: IconThemeData(color: destructiveColor, size: 20),
      titleTextStyle: typography.base.copyWith(
        color: destructiveColor,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: typography.sm.copyWith(color: destructiveColor),
    ),
  );
}
