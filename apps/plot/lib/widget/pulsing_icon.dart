import 'package:flutter/widgets.dart';

import 'package:plot/style/colors.dart';

/// An [Icon] that pulses its color between muted and the supplied
/// [primaryColor]. Used to indicate active background processing.
class PulsingIcon extends StatefulWidget {
  const PulsingIcon({
    required this.icon,
    required this.size,
    required this.primaryColor,
    super.key,
  });

  final IconData icon;
  final double size;
  final Color primaryColor;

  @override
  State<PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<PulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutQuart),
    );
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor = context.colour.muted.withValues(alpha: 0.4);

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final color = Color.lerp(
          mutedColor,
          widget.primaryColor,
          _animation.value,
        )!;
        return Icon(widget.icon, size: widget.size, color: color);
      },
    );
  }
}
