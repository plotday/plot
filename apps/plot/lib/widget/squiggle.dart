import 'package:flutter/material.dart';

class Squiggle extends StatelessWidget {
  final Color color;
  final double strokeWidth;

  const Squiggle({
    this.color = Colors.grey,
    this.strokeWidth = 2.0,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SquigglyLinePainter(
        color: color,
        strokeWidth: strokeWidth,
      ),
    );
  }
}

class _SquigglyLinePainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _SquigglyLinePainter({
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final path = Path();

    // Start at the left side of the widget
    path.moveTo(0, size.height / 2);

    // Number of waves depends on widget width
    final wavelength = size.width / 20;
    final amplitude = size.height / 4;

    // Adjust control points for smooth curves
    for (double x = 0; x < size.width; x += wavelength) {
      final controlPoint1 =
          Offset(x + wavelength / 4, size.height / 2 - amplitude);
      final controlPoint2 =
          Offset(x + 3 * wavelength / 4, size.height / 2 + amplitude);
      final endPoint = Offset(x + wavelength, size.height / 2);

      path.cubicTo(controlPoint1.dx, controlPoint1.dy, controlPoint2.dx,
          controlPoint2.dy, endPoint.dx, endPoint.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
