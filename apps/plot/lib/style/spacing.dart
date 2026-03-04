import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart' show ThemeExtension;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Spacing scale for consistent layout throughout the app.
/// Use these values for padding, margins, and gaps instead of hardcoded numbers.
/// Typography-related spacing and border radii should continue to use their own values.
class PlotSpacing extends ThemeExtension<PlotSpacing> {
  /// Extra small spacing (2.0) - Rare, for very tight spacing
  final double xs;

  /// Small spacing (4.0) - Tight spacing between related elements
  final double sm;

  /// Medium spacing (8.0) - Most common, default spacing for most UI elements
  final double md;

  /// Large spacing (12.0) - Comfortable spacing between elements
  final double lg;

  /// Extra large spacing (16.0) - Generous spacing for separation
  final double xl;

  /// 2X large spacing (24.0) - Large section spacing
  final double xxl;

  /// 3X large spacing (32.0) - Maximum spacing for major sections
  final double xxxl;

  const PlotSpacing({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
    required this.xxxl,
  });

  /// Default spacing values used as fallback when theme extension isn't registered.
  /// This ensures error UI can render even when theme initialization fails.
  static const PlotSpacing fallback = PlotSpacing(
    xs: 2.0,
    sm: 6.0,
    md: 10.0,
    lg: 14.0,
    xl: 20.0,
    xxl: 28.0,
    xxxl: 36.0,
  );

  @override
  PlotSpacing copyWith({
    double? xs,
    double? sm,
    double? md,
    double? lg,
    double? xl,
    double? xxl,
    double? xxxl,
  }) => PlotSpacing(
    xs: xs ?? this.xs,
    sm: sm ?? this.sm,
    md: md ?? this.md,
    lg: lg ?? this.lg,
    xl: xl ?? this.xl,
    xxl: xxl ?? this.xxl,
    xxxl: xxxl ?? this.xxxl,
  );

  /// Standard widget padding: `EdgeInsets.all(lg)`.
  EdgeInsets get padding => EdgeInsets.all(lg);

  /// Compact widget padding: `EdgeInsets.symmetric(horizontal: lg, vertical: sm)`.
  EdgeInsets get paddingSm => EdgeInsets.symmetric(horizontal: lg, vertical: sm);

  @override
  PlotSpacing lerp(PlotSpacing? other, double t) {
    if (other is! PlotSpacing) {
      return this;
    }

    return PlotSpacing(
      xs: lerpDouble(xs, other.xs, t)!,
      sm: lerpDouble(sm, other.sm, t)!,
      md: lerpDouble(md, other.md, t)!,
      lg: lerpDouble(lg, other.lg, t)!,
      xl: lerpDouble(xl, other.xl, t)!,
      xxl: lerpDouble(xxl, other.xxl, t)!,
      xxxl: lerpDouble(xxxl, other.xxxl, t)!,
    );
  }
}

extension PlotSpacingExtension on FThemeData {
  /// Returns the PlotSpacing theme extension, or a fallback if not registered.
  /// This defensive approach prevents errors during startup failures when the
  /// theme extension hasn't been initialized yet.
  PlotSpacing get spacing {
    try {
      return extension<PlotSpacing>();
    } catch (_) {
      return PlotSpacing.fallback;
    }
  }
}

/// Builds spacing values for the theme.
/// Currently uses the same values for all platforms, but infrastructure is in place
/// for future responsive spacing (tighter for mobile, more relaxed for desktop).
PlotSpacing buildSpacing(BuildContext context) {
  return PlotSpacing.fallback;
}
