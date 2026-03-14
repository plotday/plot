import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/theme_color.dart';

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
    final neutral = context.theme.plotColors.veryMuted;

    return CustomPaint(
      size: const Size.square(16),
      painter: _PriorityNotificationPainter(
        ringColor: active ? accent.withValues(alpha: 0.65) : null,
        dotColor: unread
            ? accent.withValues(alpha: 0.7)
            : neutral.withValues(alpha: 0.2),
      ),
    );
  }
}

class _PriorityNotificationPainter extends CustomPainter {
  _PriorityNotificationPainter({
    required this.ringColor,
    required this.dotColor,
  });

  final Color? ringColor;
  final Color dotColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Outer ring — only drawn when active
    if (ringColor != null) {
      final ringPaint = Paint()
        ..color = ringColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(center, 5.5, ringPaint);
    }

    // Inner dot
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.0, dotPaint);
  }

  @override
  bool shouldRepaint(_PriorityNotificationPainter oldDelegate) {
    return ringColor != oldDelegate.ringColor ||
        dotColor != oldDelegate.dotColor;
  }
}
