import 'package:flutter/widgets.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';

/// A widget that provides a pulsing background effect with smooth transitions.
///
/// When [isAnimating] is true, the background pulses gently between two opacity
/// levels. When [isAnimating] becomes false, the effect fades out quickly but
/// smoothly over ~200ms rather than stopping abruptly.
class AnimatedBackground extends StatefulWidget {
  /// The theme color to use for the background. If null, no background is shown.
  final ThemeColor? color;

  /// Whether the pulsing animation is active.
  final bool isAnimating;

  /// The child widget to display over the animated background.
  final Widget child;

  const AnimatedBackground({
    super.key,
    required this.color,
    required this.isAnimating,
    required this.child,
  });

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _fadeOutController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _fadeOutAnimation;

  bool _wasAnimating = false;

  @override
  void initState() {
    super.initState();

    // Pulse animation: 1.5s repeating for gentle pulsing effect
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 0.05, end: 0.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Fade-out animation: 200ms quick but smooth fade to zero
    _fadeOutController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _fadeOutAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeOutController, curve: Curves.easeOut),
    );

    // Start animating if needed
    _wasAnimating = widget.isAnimating;
    if (widget.isAnimating) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AnimatedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle isAnimating state changes
    if (widget.isAnimating != _wasAnimating) {
      if (widget.isAnimating) {
        // Start pulsing
        _fadeOutController.reset();
        _pulseController.repeat(reverse: true);
      } else {
        // Start fade out
        _pulseController.stop();
        _fadeOutController.forward(from: 0.0);
      }
      _wasAnimating = widget.isAnimating;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.color == null) {
      return widget.child;
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _fadeOutController]),
      builder: (context, child) {
        double opacity;

        if (widget.isAnimating) {
          // Currently pulsing
          opacity = _pulseAnimation.value;
        } else if (_fadeOutController.isAnimating) {
          // Fading out - multiply pulse value by fade factor
          opacity = _pulseAnimation.value * (1.0 - _fadeOutAnimation.value);
        } else {
          // Completely off
          opacity = 0.0;
        }

        // Convert ThemeColor to actual Color using the app's color system
        final backgroundColor = context.colour.colours.fromTheme(widget.color);

        return Container(
          decoration: BoxDecoration(
            color: backgroundColor.withValues(alpha: opacity),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
