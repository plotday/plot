import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Wraps a single scheduler row so the Left/Right cursor keys adjust its value
/// when the row holds form focus. Plain `←`/`→` do the small step;
/// `Shift+←`/`Shift+→` do the large jump. Every other key (↑/↓/Tab/Enter/Esc)
/// is returned as ignored so [FormModal]'s own navigation handles it.
///
/// Implicit edit-mode: these handlers only fire when [focusNode] (the row) has
/// focus. When the user clicks into an inner editable field, that field owns
/// focus and consumes `←`/`→` for its text cursor, so typing still works.
///
/// [highlightColor] is painted behind [child] when non-null (the caller decides
/// the row is active and supplies the themed color); null = no background.
class StepperRow extends StatelessWidget {
  const StepperRow({
    required this.focusNode,
    required this.child,
    this.highlightColor,
    this.onStepBack,
    this.onStepForward,
    this.onJumpBack,
    this.onJumpForward,
    super.key,
  });

  final FocusNode focusNode;
  final Widget child;
  final Color? highlightColor;
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;
  final VoidCallback? onJumpBack;
  final VoidCallback? onJumpForward;

  bool get _shiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftRight);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final cb = _shiftPressed ? onJumpBack : onStepBack;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final cb = _shiftPressed ? onJumpForward : onStepForward;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final color = highlightColor;
    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: color != null ? ColoredBox(color: color, child: child) : child,
    );
  }
}
