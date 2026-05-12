import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Draws the pill's pomodoro progress as a stroked rounded-rectangle
/// outline that fills clockwise from the top. The background outline
/// always renders at full circumference; the foreground arc traces
/// `progress` (0..1) of the same path.
///
/// The painter targets the pill geometry — a stadium-shaped (fully
/// rounded) rectangle. Drawing along that perimeter lets the arc
/// visually own the existing pill border instead of stacking a second
/// shape inside it.
class PomodoroRingPainter extends CustomPainter {
  PomodoroRingPainter({
    required this.progress,
    required this.backgroundColor,
    required this.foregroundColor,
    this.strokeWidth = 1.5,
  });

  /// 0..1 — fraction of the planned pomodoro that has elapsed.
  final double progress;
  final Color backgroundColor;
  final Color foregroundColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final radius = Radius.circular(rect.height / 2);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    final bg = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rrect, bg);

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;

    // Build the full perimeter as a single Path, then extract the
    // leading [clamped] fraction via PathMetric. This handles the
    // stadium corners correctly without per-arc math.
    final perimeter = Path()..addRRect(rrect);
    final metrics = perimeter.computeMetrics().toList();
    if (metrics.isEmpty) return;
    // Rotate the start point to 12-o-clock: PathMetric on an RRect
    // starts mid-right side; offset by 3/4 of the perimeter so the
    // visual sweep begins at the top.
    final fg = Paint()
      ..color = foregroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    for (final metric in metrics) {
      final length = metric.length;
      final start = length * 0.75;
      final sweep = length * clamped;
      final end = start + sweep;
      // Wrap around the seam if the sweep crosses the end of the path.
      if (end <= length) {
        canvas.drawPath(metric.extractPath(start, end), fg);
      } else {
        canvas.drawPath(metric.extractPath(start, length), fg);
        canvas.drawPath(metric.extractPath(0, end - length), fg);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PomodoroRingPainter old) =>
      old.progress != progress
      || old.backgroundColor != backgroundColor
      || old.foregroundColor != foregroundColor
      || old.strokeWidth != strokeWidth;
}

/// Helper to coerce a fraction into the painter's clamped range. Kept
/// outside the painter so callers can use it for things like the pill's
/// "ring fully filled" decision during grace.
double clampProgress(double value) {
  if (value.isNaN) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

/// Convenience for tests / debug: stadium perimeter length.
double stadiumPerimeter(Size size) {
  final r = size.height / 2;
  final straight = math.max(0.0, size.width - 2 * r);
  return 2 * straight + 2 * math.pi * r;
}
