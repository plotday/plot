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
    final r = rect.height / 2;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));

    final bg = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rrect, bg);

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;

    // Build the perimeter starting at top-center (12 o'clock) and
    // running clockwise, so PathMetric's 0 offset is the visual start
    // of the sweep. Avoids relying on Path.addRRect's implicit start.
    final centerX = rect.center.dx;
    final cy = rect.center.dy;
    final perimeter = Path()
      ..moveTo(centerX, rect.top)
      ..lineTo(rect.right - r, rect.top)
      ..arcTo(
        Rect.fromCircle(center: Offset(rect.right - r, cy), radius: r),
        -math.pi / 2,
        math.pi,
        false,
      )
      ..lineTo(rect.left + r, rect.bottom)
      ..arcTo(
        Rect.fromCircle(center: Offset(rect.left + r, cy), radius: r),
        math.pi / 2,
        math.pi,
        false,
      )
      ..lineTo(centerX, rect.top);

    final metrics = perimeter.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final fg = Paint()
      ..color = foregroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    for (final metric in metrics) {
      final length = metric.length;
      final sweep = length * clamped;
      canvas.drawPath(metric.extractPath(0, sweep), fg);
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
