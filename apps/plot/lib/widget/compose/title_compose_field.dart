import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Title row inside the compose surface. Always-editable single-line
/// FTextField with the shared [ComposeFieldRow] chrome and ghost styling.
class TitleComposeField extends StatefulWidget {
  const TitleComposeField({
    super.key,
    required this.title,
    required this.onChanged,
    this.onTabForward,
  });

  /// Current draft title (null when unset).
  final String? title;

  /// Persist a new value. Pass `null` to clear.
  final Future<void> Function(String? next) onChanged;

  /// Called when the user presses Tab (no Shift) inside the field. Page
  /// wires this to focus the note editor so the compose-surface flow
  /// continues into the body. Shift-Tab is left to the default focus
  /// traversal so the user lands on the previous compose field.
  final VoidCallback? onTabForward;

  @override
  State<TitleComposeField> createState() => TitleComposeFieldState();
}

class TitleComposeFieldState extends State<TitleComposeField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title ?? '');
    _focusNode = FocusNode();
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    _commit(_controller.text);
  }

  @override
  void didUpdateWidget(TitleComposeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // External title changes (e.g. clear after submit) only update the
    // controller when the field isn't focused, to avoid clobbering an
    // in-progress edit.
    if (!_focusNode.hasFocus && (widget.title ?? '') != _controller.text) {
      _controller.text = widget.title ?? '';
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Request focus on the title input. Used by the ⌘⇧H shortcut.
  void focus() => _focusNode.requestFocus();

  Future<void> _commit(String value) async {
    final trimmed = value.trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (next != widget.title) {
      await widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ComposeFieldRow(
      icon: FontAwesomeIcons.t,
      tooltip: 'Title',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyH,
        shift: true,
      ),
      onTapField: focus,
      child: Focus(
        // Intercept Tab BEFORE the FTextField sees it. Without an explicit
        // hop into the note editor, default focus traversal lands inside
        // the SuperEditor's internal focus group and the visual focus
        // doesn't land on the editable body.
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleTabKey,
        child: FTextField(
          control: .managed(controller: _controller),
          focusNode: _focusNode,
          hint: 'Title',
          textInputAction: TextInputAction.next,
          onSubmit: _commit,
          style: ghostFieldStyle(context),
        ),
      ),
    );
  }

  KeyEventResult _handleTabKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) return KeyEventResult.ignored;
    final cb = widget.onTabForward;
    if (cb == null) return KeyEventResult.ignored;
    cb();
    return KeyEventResult.handled;
  }
}
