import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/theme.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';

class PriorityNotification extends StatelessWidget {
  const PriorityNotification({
    required this.unread,
    required this.active,
    required this.color,
    this.colorOverride,
    super.key,
  });

  final bool unread;
  final bool active;
  final ThemeColor color;

  /// When set, paint the active/unread indicator using this color instead of
  /// the accent derived from [color]. Used by the monochrome priority frame
  /// where the indicator dims to a single foreground tone at rest.
  final Color? colorOverride;

  String? get _tooltip {
    if (active && unread) return 'Active and unread threads';
    if (active) return 'Active threads';
    if (unread) return 'Unread threads';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final accent = colorOverride ?? context.colour.colours.fromTheme(color);
    final iconSize = isMobilePlatform() ? 13.0 : 12.0;
    final icon = _buildIcon(context, accent, iconSize);
    final tooltip = _tooltip;
    if (tooltip != null && hasPhysicalKeyboard()) {
      return FTooltip(
        tipBuilder: (context, controller) => Text(tooltip),
        child: icon,
      );
    }
    return icon;
  }

  Widget _buildIcon(BuildContext context, Color accent, double iconSize) {
    if (active) {
      if (unread) {
        final isDark = context.read<ThemeBloc>().isDarkMode(context);
        return SizedBox.square(
          dimension: 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: isDark ? 0.55 : 0.45,
                child: Icon(PlotIcon.todoFilled, size: iconSize, color: accent),
              ),
              Icon(PlotIcon.todo, size: iconSize, color: accent),
            ],
          ),
        );
      }
      return SizedBox.square(
        dimension: 16,
        child: Icon(PlotIcon.todo, size: iconSize, color: accent),
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
