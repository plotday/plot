import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// The current swipe zone based on drag distance.
enum _SwipeZone { idle, short, long }

/// A widget that enables swipe gestures on touch devices to reveal and execute commands.
///
/// Only works on touch devices. Supports optional start (right swipe) and end (left swipe) commands
/// with both short and long thresholds per direction.
class Swipeable extends StatefulWidget {
  final Widget child;
  final Command? startCommand; // Right swipe short command
  final Command? startLongCommand; // Right swipe long command
  final Command? endCommand; // Left swipe short command
  final Command? endLongCommand; // Left swipe long command

  /// When set, on release in an active zone the child slides off-screen
  /// instead of sliding back to origin. The callback receives the resolved
  /// command. The caller is responsible for executing the command.
  final Future<void> Function(Command command)? exitOnActivation;

  const Swipeable({
    required this.child,
    this.startCommand,
    this.startLongCommand,
    this.endCommand,
    this.endLongCommand,
    this.exitOnActivation,
    super.key,
  });

  @override
  State<Swipeable> createState() => _SwipeableState();
}

class _SwipeableState extends State<Swipeable>
    with TickerProviderStateMixin {
  static const double _shortThreshold = 80.0;
  static const double _longThreshold = 180.0;
  static const double _dragStartThreshold =
      8.0; // Threshold to distinguish swipe from scroll

  double _dragOffset = 0.0;
  double _startDragX = 0.0;
  _SwipeZone _zone = _SwipeZone.idle;
  bool _isDragging = false;
  late AnimationController _slideBackController;
  late Animation<double> _slideBackAnimation;
  late AnimationController _slideOffController;
  late Animation<double> _slideOffAnimation;

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
    _slideOffController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _slideOffAnimation =
        Tween<double>(begin: 0, end: 0).animate(
          CurvedAnimation(parent: _slideOffController, curve: Curves.easeIn),
        )..addListener(() {
          setState(() {
            _dragOffset = _slideOffAnimation.value;
          });
        });
  }

  @override
  void dispose() {
    _slideOffController.dispose();
    _slideBackController.dispose();
    super.dispose();
  }

  /// Whether a given direction has any command at all.
  bool _hasAnyCommand({required bool right}) {
    if (right) return widget.startCommand != null || widget.startLongCommand != null;
    return widget.endCommand != null || widget.endLongCommand != null;
  }

  /// Get the short and long commands for the current drag direction.
  (Command? short, Command? long) _commandsForDirection({required bool right}) {
    if (right) return (widget.startCommand, widget.startLongCommand);
    return (widget.endCommand, widget.endLongCommand);
  }

  /// Compute the swipe zone from absolute offset, accounting for fallback
  /// when only one command exists per direction.
  _SwipeZone _computeZone(double absOffset, {required bool right}) {
    final (shortCmd, longCmd) = _commandsForDirection(right: right);

    if (absOffset < _shortThreshold) return _SwipeZone.idle;

    // Only long command: promote to short threshold
    if (shortCmd == null && longCmd != null) return _SwipeZone.short;

    // Only short command: short zone extends past long threshold
    if (longCmd == null) return _SwipeZone.short;

    // Both commands exist
    if (absOffset >= _longThreshold) return _SwipeZone.long;
    return _SwipeZone.short;
  }

  /// Get the command that would execute on release for the current zone and direction.
  Command? _activeCommand({required bool right, required _SwipeZone zone}) {
    if (zone == _SwipeZone.idle) return null;
    final (shortCmd, longCmd) = _commandsForDirection(right: right);

    if (zone == _SwipeZone.long && longCmd != null) return longCmd;
    // Short zone, or long zone fallback when only short exists
    return shortCmd ?? longCmd;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _startDragX = details.globalPosition.dx;
    _isDragging = false;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final totalDragDistance = details.globalPosition.dx - _startDragX;

    final isDraggingRight = totalDragDistance > 0;
    final isDraggingLeft = totalDragDistance < 0;

    final canSwipeRight = _hasAnyCommand(right: true) && isDraggingRight;
    final canSwipeLeft = _hasAnyCommand(right: false) && isDraggingLeft;

    if (!canSwipeRight && !canSwipeLeft) return;

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
      if (!_hasAnyCommand(right: true)) {
        _dragOffset = _dragOffset.clamp(double.negativeInfinity, 0.0);
      }
      if (!_hasAnyCommand(right: false)) {
        _dragOffset = _dragOffset.clamp(0.0, double.infinity);
      }

      final isRight = _dragOffset > 0;
      final previousZone = _zone;
      _zone = _computeZone(_dragOffset.abs(), right: isRight);

      // Haptic feedback on zone transitions
      if (_zone != previousZone) {
        if (_zone == _SwipeZone.short) {
          HapticFeedback.lightImpact();
        } else if (_zone == _SwipeZone.long) {
          HapticFeedback.mediumImpact();
        }
      }
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) async {
    if (!_isDragging) return;

    final isRight = _dragOffset > 0;
    final command = _activeCommand(right: isRight, zone: _zone);

    // Exit mode: slide off-screen instead of sliding back
    if (_zone != _SwipeZone.idle &&
        command != null &&
        widget.exitOnActivation != null) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final target = isRight ? screenWidth : -screenWidth;

      _slideOffAnimation = Tween<double>(
        begin: _dragOffset,
        end: target,
      ).animate(
        CurvedAnimation(parent: _slideOffController, curve: Curves.easeIn),
      );

      _slideOffController.reset();
      await _slideOffController.forward();

      if (mounted) {
        await widget.exitOnActivation!(command);
      }

      // Reset state (widget may be disposed by now via removal)
      if (mounted) {
        setState(() {
          _dragOffset = 0;
          _startDragX = 0;
          _zone = _SwipeZone.idle;
          _isDragging = false;
        });
      }
      return;
    }

    // Default: animate slide back to original position
    _slideBackAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _slideBackController, curve: Curves.easeOut),
    );

    _slideBackController.reset();
    await _slideBackController.forward();

    // Execute command if in an active zone
    if (_zone != _SwipeZone.idle && command != null && mounted) {
      await context.run(command);
    }

    // Reset state
    setState(() {
      _dragOffset = 0;
      _startDragX = 0;
      _zone = _SwipeZone.idle;
      _isDragging = false;
    });
  }

  void _onHorizontalDragCancel() {
    if (_isDragging) {
      setState(() {
        _dragOffset = 0;
        _startDragX = 0;
        _zone = _SwipeZone.idle;
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
    final revealWidth = _dragOffset.abs();

    // Determine which command to display — always show the command that
    // *would* execute so the icon+label are consistent throughout the gesture.
    final command = _activeCommand(right: isRightSwipe, zone: _zone);
    final displayCommand = command ?? () {
      final (shortCmd, longCmd) = _commandsForDirection(right: isRightSwipe);
      return shortCmd ?? longCmd;
    }();
    if (displayCommand == null) return const SizedBox.shrink();

    final isActivated = _zone != _SwipeZone.idle;

    final backgroundColor = _zone == _SwipeZone.long
        ? context.colour.accentBackground.withValues(alpha: 0.2)
        : isActivated
            ? context.colour.accentBackground
            : context.colour.accentBackground.withAlpha(80);

    final foregroundColor = isActivated
        ? context.colour.accent
        : context.colour.foreground.withValues(alpha: 0.5);

    // Fixed position from the swiped edge so the icon+label slide out
    // with the content rather than jumping around as the reveal grows.
    const double contentInset = 24.0;

    return Positioned(
      left: isRightSwipe ? 0 : null,
      right: !isRightSwipe ? 0 : null,
      top: 0,
      bottom: 0,
      width: revealWidth,
      child: Container(
        color: backgroundColor,
        child: OverflowBox(
          alignment: isRightSwipe ? Alignment.centerRight : Alignment.centerLeft,
          maxWidth: double.infinity,
          child: Padding(
            padding: EdgeInsets.only(
              left: isRightSwipe ? 0 : contentInset,
              right: isRightSwipe ? contentInset : 0,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (displayCommand.icon != null) ...[
                  Icon(displayCommand.icon, size: context.theme.iconSizes.lg, color: foregroundColor),
                  const SizedBox(width: 6),
                ],
                Text(
                  displayCommand.title,
                  style: context.theme.typography.sm.copyWith(
                    color: foregroundColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
