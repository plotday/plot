import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart' show ThemeExtension;
import 'package:forui/forui.dart';

/// Icon sizes that correspond to typography sizes.
/// Icons should almost always use the base size, except when displayed
/// with text of a different size (e.g., a ListTile header using the sm size).
class PlotIconSizes extends ThemeExtension<PlotIconSizes> {
  final double xs;
  final double sm;
  final double base;
  final double lg;
  final double xl;

  const PlotIconSizes({
    required this.xs,
    required this.sm,
    required this.base,
    required this.lg,
    required this.xl,
  });

  /// Default icon sizes used as fallback when theme extension isn't registered.
  /// This ensures error UI can render even when theme initialization fails.
  static const PlotIconSizes fallback = PlotIconSizes(
    xs: 12.0,
    sm: 14.0,
    base: 16.0,
    lg: 18.0,
    xl: 20.0,
  );

  /// Ratio of a *leading* icon's glyph size to its adjacent label font size.
  ///
  /// A glyph drawn at its full em box reads ~30–40% larger than the capital
  /// letters beside it, because text only fills roughly its cap height (~0.7em)
  /// of the line. So an icon set 1:1 with the font size (the old default, since
  /// [base] equals the `md` font size) looks too big and crowds the label. A
  /// leading icon is instead sized to roughly cap height — about one step down
  /// the size ladder — so it sits optically level with the text. Tune here to
  /// move every leading icon at once.
  static const double leadingRatio = 0.86;

  /// Cap-height-matched glyph size for a leading icon sitting before a label of
  /// [labelSize] (a sidebar row, menu item, picker option, compose row, …).
  /// Prefer this over matching the icon to the font size 1:1. See
  /// [leadingRatio].
  double leadingFor(double labelSize) => labelSize * leadingRatio;

  /// Convenience leading-icon size for body-text (`md`) labels — equal to
  /// `leadingFor(base)`, roughly the `sm` token. Use for fixed-size rows such
  /// as the sidebar, where every leading glyph shares one size so the icon
  /// column reads as a single rhythm regardless of each row's label size.
  double get leading => leadingFor(base);

  @override
  PlotIconSizes copyWith({
    double? xs,
    double? sm,
    double? base,
    double? lg,
    double? xl,
  }) => PlotIconSizes(
    xs: xs ?? this.xs,
    sm: sm ?? this.sm,
    base: base ?? this.base,
    lg: lg ?? this.lg,
    xl: xl ?? this.xl,
  );

  @override
  PlotIconSizes lerp(PlotIconSizes? other, double t) {
    if (other is! PlotIconSizes) {
      return this;
    }

    return PlotIconSizes(
      xs: lerpDouble(xs, other.xs, t)!,
      sm: lerpDouble(sm, other.sm, t)!,
      base: lerpDouble(base, other.base, t)!,
      lg: lerpDouble(lg, other.lg, t)!,
      xl: lerpDouble(xl, other.xl, t)!,
    );
  }
}

extension PlotIconSizesExtension on FThemeData {
  /// Returns the PlotIconSizes theme extension, or a fallback if not registered.
  /// This defensive approach prevents errors during startup failures when the
  /// theme extension hasn't been initialized yet.
  PlotIconSizes get iconSizes {
    try {
      return extension<PlotIconSizes>();
    } catch (_) {
      return PlotIconSizes.fallback;
    }
  }
}
