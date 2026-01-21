import 'package:plot/command/command.dart';
import 'package:plot/widget/widget.dart';

/// A button that pulses its color between muted and primary colors.
/// Used for twist tag icons to indicate active processing.
class PulsingColorButton extends StatefulWidget {
  const PulsingColorButton(
    this.command, {
    required this.primaryColor,
    super.key,
  });

  final Command command;
  final Color primaryColor;

  @override
  State<PulsingColorButton> createState() => _PulsingColorButtonState();
}

class _PulsingColorButtonState extends State<PulsingColorButton>
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
    final mutedColor = context.colour.muted.withOpacity(0.4);

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final color = Color.lerp(
          mutedColor,
          widget.primaryColor,
          _animation.value,
        )!;
        return Button.icon(
          widget.command,
          selected: true,
          selectedColor: color,
        );
      },
    );
  }
}
