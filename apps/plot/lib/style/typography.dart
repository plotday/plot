import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/style/plot_icon_sizes.dart';

/// Font and icon sizes for desktop/web platforms and larger screens.
const _desktopSizes = (xs: 11.0, sm: 13.0, base: 15.0, lg: 18.0, xl: 22.0);

/// Font and icon sizes for mobile platforms with small screens.
const _mobileSizes = (xs: 12.0, sm: 14.0, base: 16.0, lg: 20.0, xl: 24.0);

/// Detects if we should use the larger, touch-friendly mobile sizing.
///
/// True for any mobile platform (iOS/Android, native or web) — including
/// wide tablets like iPad. This deliberately mirrors the predicate that
/// drives ghost button/icon padding in `style/button.dart`
/// (`isMobilePlatform()`), so a device's type scale and its touch chrome
/// stay consistent. Previously this was also gated on `screenWidth < 660`,
/// which left wide iPads with desktop-small fonts inside touch-sized bands —
/// the header text looked undersized and floated high in the band.
///
/// `context` is retained for signature stability with the callers below.
bool _useMobileFonts(BuildContext context) {
  return isMobilePlatform();
}

FTypography buildTypography(BuildContext context, FColors colorScheme) {
  // Choose the appropriate font sizes
  final sizes = _useMobileFonts(context) ? _mobileSizes : _desktopSizes;

  final baseTypography = FTypography.inherit(
    colors: colorScheme,
    fontFamily: 'Figtree',
    touch: false,
  );
  final baseStyle = baseTypography.md;

  return baseTypography.copyWith(
    xs: baseStyle.copyWith(fontSize: sizes.xs, letterSpacing: 0.2),
    sm: baseStyle.copyWith(fontSize: sizes.sm, letterSpacing: 0.1),
    md: baseStyle.copyWith(fontSize: sizes.base),
    lg: baseStyle.copyWith(
      fontSize: sizes.lg,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.15,
    ),
    xl: baseStyle.copyWith(
      fontSize: sizes.xl,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.3,
    ),
  );
}

/// Builds icon sizes that match the typography sizes.
/// Icons should almost always use the base size, except when displayed
/// with text of a different size (e.g., a ListTile header using the sm size).
PlotIconSizes buildIconSizes(BuildContext context) {
  // Choose the appropriate icon sizes to match font sizes
  final sizes = _useMobileFonts(context) ? _mobileSizes : _desktopSizes;

  return PlotIconSizes(
    xs: sizes.xs,
    sm: sizes.sm,
    base: sizes.base,
    lg: sizes.lg,
    xl: sizes.xl,
  );
}
