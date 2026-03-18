import 'package:plot/widget/widget.dart';

/// Wraps a child widget and can animate its removal from the layout.
///
/// Call [AnimatedRemovalState.remove] to trigger the exit animation:
/// - Height collapses from full to zero (both platforms)
/// - Optional fade-out before collapse (desktop icon-click path)
///
/// The [onRemoved] callback fires after all animations complete.
class AnimatedRemoval extends StatefulWidget {
  final Widget child;
  final VoidCallback? onRemoved;

  const AnimatedRemoval({
    required this.child,
    this.onRemoved,
    super.key,
  });

  @override
  State<AnimatedRemoval> createState() => AnimatedRemovalState();
}

class AnimatedRemovalState extends State<AnimatedRemoval>
    with TickerProviderStateMixin {
  static const _collapseDuration = Duration(milliseconds: 150);
  static const _collapseDelay = Duration(milliseconds: 80);
  static const _fadeDuration = Duration(milliseconds: 120);
  static const _fadeDelay = Duration(milliseconds: 50);

  late final AnimationController _collapseController;
  late final AnimationController _fadeController;
  late final Animation<double> _collapseAnimation;
  late final Animation<double> _fadeAnimation;

  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _collapseController = AnimationController(
      duration: _collapseDuration,
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: _fadeDuration,
      vsync: this,
    );
    _collapseAnimation = CurvedAnimation(
      parent: _collapseController,
      curve: Curves.easeOut,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _collapseController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  /// Trigger the removal animation.
  ///
  /// When [fade] is true (desktop path), fades the child out before
  /// collapsing. When false (mobile path), only collapses height
  /// (the slide-off is handled by [Swipeable]).
  Future<void> remove({bool fade = false}) async {
    if (_removing) return;
    _removing = true;

    if (fade) {
      // Start fade after delay
      await Future<void>.delayed(_fadeDelay);
      if (!mounted) return;
      _fadeController.forward();
    }

    // Start collapse after delay (from the beginning of remove())
    // For fade path: collapse starts at +80ms, fade started at +50ms
    // For non-fade path: collapse starts at +80ms from call
    final elapsed = fade ? _fadeDelay : Duration.zero;
    final remaining = _collapseDelay - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
    if (!mounted) return;

    await _collapseController.forward();
    if (!mounted) return;
    widget.onRemoved?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_removing) return widget.child;

    Widget child = widget.child;

    // Apply fade if active
    if (_fadeController.isAnimating || _fadeController.isCompleted) {
      child = FadeTransition(
        opacity: ReverseAnimation(_fadeAnimation),
        child: child,
      );
    }

    // Apply height collapse
    return SizeTransition(
      sizeFactor: ReverseAnimation(_collapseAnimation),
      axisAlignment: -1.0,
      child: child,
    );
  }
}
