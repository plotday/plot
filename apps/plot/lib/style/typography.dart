import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/platform.dart';

FTypography buildTypography(BuildContext context, FColors colorScheme) {
  // Detect if we should use larger mobile fonts:
  // - Mobile platform (iOS/Android, native or web)
  // - Screen width < 660px (single-panel breakpoint)
  final screenWidth = MediaQuery.sizeOf(context).width;
  final useMobileFonts = isMobilePlatform() && screenWidth < 660;

  // Font sizes for desktop/web platforms and larger screens
  final desktopSizes = (xs: 11.0, sm: 13.0, base: 15.0, lg: 18.0, xl: 22.0);

  // Larger font sizes for mobile platforms with small screens
  final mobileSizes = (xs: 12.0, sm: 14.0, base: 16.0, lg: 20.0, xl: 24.0);

  // Choose the appropriate font sizes
  final sizes = useMobileFonts ? mobileSizes : desktopSizes;

  return FTypography.inherit(
    colors: colorScheme,
    defaultFontFamily: 'Figtree',
  ).copyWith(
    xs: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: sizes.xs),
    sm: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: sizes.sm),
    base: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: sizes.base),
    lg: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: sizes.lg),
    xl: FTypography.inherit(
      colors: colorScheme,
      defaultFontFamily: 'Figtree',
    ).base.copyWith(fontSize: sizes.xl),
  );
}
