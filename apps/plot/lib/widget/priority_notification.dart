import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/theme_color.dart';

class PriorityNotification extends StatelessWidget {
  const PriorityNotification({
    required this.unread,
    required this.color,
    this.colorOverride,
    super.key,
  });

  final bool unread;
  final ThemeColor color;

  /// When set, paint the unread indicator using this color instead of
  /// the accent derived from [color]. Used by the monochrome priority frame
  /// where the indicator dims to a single foreground tone at rest.
  final Color? colorOverride;

  @override
  Widget build(BuildContext context) {
    final accent = colorOverride ?? context.colour.colours.fromTheme(color);
    final icon = _buildIcon(accent);
    if (unread && hasPhysicalKeyboard()) {
      return FTooltip(
        tipBuilder: (context, controller) => const Text('Unread threads'),
        child: icon,
      );
    }
    return icon;
  }

  Widget _buildIcon(Color accent) {
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
