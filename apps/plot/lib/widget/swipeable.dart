import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// A widget that enables swipe gestures on touch devices to reveal and execute commands.
///
/// Only works on touch devices. Supports optional start (right swipe) and end (left swipe) commands.
/// The revealed action button changes from disabled to primary styling when the activation threshold is reached.
class Swipeable extends StatefulWidget {
  final Widget child;
  final Command? startCommand; // Right swipe command
  final Command? endCommand; // Left swipe command

  const Swipeable({
    required this.child,
    this.startCommand,
    this.endCommand,
    super.key,
  });

  @override
  State<Swipeable> createState() => _SwipeableState();
}

class _SwipeableState extends State<Swipeable>
    with SingleTickerProviderStateMixin {
  static const double _activationThreshold = 100.0; // ~1/3 screen width (~33%)
  static const double _dragStartThreshold =
      8.0; // Threshold to distinguish swipe from scroll

  double _dragOffset = 0.0;
  double _startDragX = 0.0;
  bool _isActivated = false;
  bool _isDragging = false;
  late AnimationController _slideBackController;
  late Animation<double> _slideBackAnimation;

  @override
  void initState() {
    super.initState();
    _slideBackController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _slideBackAnimation =
        Tween<double>(begin: 0, end: 0).animate(
          CurvedAnimation(parent: _slideBackController, curve: Curves.easeOut),
        )..addListener(() {
          setState(() {
            _dragOffset = _slideBackAnimation.value;
          });
        });
  }

  @override
  void dispose() {
    _slideBackController.dispose();
    super.dispose();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    // Record the starting position for threshold calculation
    _startDragX = details.globalPosition.dx;
    _isDragging = false; // Will be set to true once threshold is exceeded
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    // Calculate total horizontal distance from start
    final totalDragDistance = details.globalPosition.dx - _startDragX;

    // Determine swipe direction
    final isDraggingRight = totalDragDistance > 0;
    final isDraggingLeft = totalDragDistance < 0;

    // Check if we have a command for this direction
    final canSwipeRight = widget.startCommand != null && isDraggingRight;
    final canSwipeLeft = widget.endCommand != null && isDraggingLeft;

    if (!canSwipeRight && !canSwipeLeft) return;

    // Only start dragging if horizontal movement exceeds threshold
    // This prevents accidental swipes during vertical scrolling
    if (!_isDragging) {
      if (totalDragDistance.abs() >= _dragStartThreshold) {
        _isDragging = true;
      } else {
        return;
      }
    }

    setState(() {
      _dragOffset += details.delta.dx;

      // Clamp to valid range based on available commands
      if (widget.startCommand == null) {
        _dragOffset = _dragOffset.clamp(double.negativeInfinity, 0.0);
      }
      if (widget.endCommand == null) {
        _dragOffset = _dragOffset.clamp(0.0, double.infinity);
      }

      // Check activation state
      final wasActivated = _isActivated;
      _isActivated = _dragOffset.abs() >= _activationThreshold;

      // Trigger haptic feedback when crossing threshold into activated state
      if (_isActivated && !wasActivated) {
        HapticFeedback.lightImpact();
      }
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) async {
    if (!_isDragging) return;

    final wasActivated = _isActivated;
    final command = _dragOffset > 0 ? widget.startCommand : widget.endCommand;

    // Animate slide back to original position
    _slideBackAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _slideBackController, curve: Curves.easeOut),
    );

    _slideBackController.reset();
    await _slideBackController.forward();

    // Execute command if activated
    if (wasActivated && command != null && mounted) {
      await context.run(command);
    }

    // Reset state
    setState(() {
      _dragOffset = 0;
      _startDragX = 0;
      _isActivated = false;
      _isDragging = false;
    });
  }

  void _onHorizontalDragCancel() {
    // Reset state if drag is cancelled
    if (_isDragging) {
      setState(() {
        _dragOffset = 0;
        _startDragX = 0;
        _isActivated = false;
        _isDragging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer
            >(
              () =>
                  HorizontalDragGestureRecognizer(debugOwner: this)
                    ..dragStartBehavior = DragStartBehavior.down,
              (HorizontalDragGestureRecognizer instance) {
                instance
                  ..onStart = _onHorizontalDragStart
                  ..onUpdate = _onHorizontalDragUpdate
                  ..onEnd = _onHorizontalDragEnd
                  ..onCancel = _onHorizontalDragCancel;
              },
            ),
      },
      child: Stack(
        children: [
          // Background action button (slides in from edge)
          if (_dragOffset != 0) _buildSwipeAction(context),
          // Main content (translates with drag)
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }

  Widget _buildSwipeAction(BuildContext context) {
    final isRightSwipe = _dragOffset > 0;
    final command = isRightSwipe ? widget.startCommand : widget.endCommand;

    if (command == null) return const SizedBox.shrink();

    // Calculate button width based on drag progress
    final revealWidth = _dragOffset.abs();

    // Determine colors based on activation state
    final backgroundColor = _isActivated
        ? context
              .colour
              .accentBackground // Primary color when activated
        : context.colour.accentBackground.withAlpha(
            80,
          ); // Disabled/muted color when not activated

    final foregroundColor = _isActivated
        ? context.colour.accent
        : context.colour.foreground.withValues(
            alpha: 0.5,
          ); // Semi-transparent when not activated

    return Positioned(
      left: isRightSwipe ? 0 : null,
      right: !isRightSwipe ? 0 : null,
      top: 0,
      bottom: 0,
      width: revealWidth,
      child: Container(
        color: backgroundColor,
        child: Center(
          child: command.icon != null
              ? Icon(command.icon, size: context.theme.iconSizes.lg, color: foregroundColor)
              : Text(
                  command.title,
                  style: context.theme.typography.sm.copyWith(
                    color: foregroundColor,
                  ),
                ),
        ),
      ),
    );
  }
}
