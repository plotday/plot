import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Title row inside the compose surface. Always-editable single-line
/// FTextField with the shared [ComposeFieldRow] chrome.
class TitleComposeField extends StatefulWidget {
  const TitleComposeField({
    super.key,
    required this.title,
    required this.onChanged,
    this.isLast = false,
  });

  /// Current draft title (null when unset).
  final String? title;

  /// Persist a new value. Pass `null` to clear.
  final Future<void> Function(String? next) onChanged;

  final bool isLast;

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
    // Commit on every keystroke (equivalent to onChange).
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
      icon: FontAwesomeIcons.pen,
      tooltip: 'Title',
      shortcut: platformSingleActivator(
        LogicalKeyboardKey.keyH,
        shift: true,
      ),
      onTapField: focus,
      isLast: widget.isLast,
      child: FTextField(
        control: .managed(controller: _controller),
        focusNode: _focusNode,
        hint: 'Title',
        textInputAction: TextInputAction.next,
        // onChange is not available in this forui version; commits are
        // driven by the TextEditingController listener added in initState.
        // onSubmit fires when the user presses Enter/next.
        onSubmit: (v) => _commit(v),
        style: FTextFieldStyleDelta.delta(
          contentPadding: EdgeInsetsGeometryDelta.value(
            const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          ),
        ),
      ),
    );
  }
}
