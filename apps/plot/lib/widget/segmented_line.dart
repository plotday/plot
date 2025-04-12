import "package:flutter/widgets.dart";

class SegmentedLine extends StatelessWidget {
  final List<double> lengths;
  final List<Color> colors;
  final double? total;

  const SegmentedLine({
    required this.lengths,
    required this.colors,
    this.total,
    super.key,
  }) : assert(lengths.length == colors.length,
            'Each length must have a corresponding color.');

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(double.infinity, 1.0),
      painter: _SegmentedLinePainter(lengths, colors, total),
    );
  }
}

class _SegmentedLinePainter extends CustomPainter {
  final List<double> lengths;
  final List<Color> colors;
  final double? total;

  _SegmentedLinePainter(this.lengths, this.colors, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();

    // Calculate the full length to be painted
    final totalLength =
        total ?? lengths.fold<double>(0, (sum, len) => sum + len);

    // Start drawing from the left
    double startX = 0.0;
    for (int i = 0; i < lengths.length; i++) {
      double proportion = lengths[i] / totalLength;
      double segmentLength = size.width * proportion;

      paint.color = colors[i];
      canvas.drawRect(
        Rect.fromLTWH(startX, 0.0, segmentLength, size.height),
        paint,
      );

      // Update the starting X position for the next segment
      startX += segmentLength;
    }

    // Draw remaining transparent section if needed
    if (total != null && startX < size.width) {
      paint.color = Color(0x00000000);
      canvas.drawRect(
        Rect.fromLTWH(startX, 0.0, size.width - startX, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
