import 'package:flutter/widgets.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';

class PriorityNotification extends StatelessWidget {
  const PriorityNotification({
    required this.unread,
    required this.active,
    required this.color,
    super.key,
  });

  final bool unread;
  final bool active;
  final ThemeColor color;

  @override
  Widget build(BuildContext context) {
    final accent = context.colour.colours.fromTheme(color);
    if (active) {
      return SizedBox.square(
        dimension: 16,
        child: Icon(
          unread ? PlotIcon.todoFilled : PlotIcon.todo,
          size: 12,
          color: accent.withValues(alpha: unread ? 0.7 : 0.85),
        ),
      );
    }

    if (!unread) return const SizedBox.square(dimension: 16);

    return SizedBox.square(
      dimension: 16,
      child: Center(
        child: CustomPaint(
          size: const Size.square(6),
          painter: _DotPainter(color: accent.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => color != oldDelegate.color;
}
