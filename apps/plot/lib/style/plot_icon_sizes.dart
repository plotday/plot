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
