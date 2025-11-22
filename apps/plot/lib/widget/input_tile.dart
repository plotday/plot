import 'package:flutter/widgets.dart';

import 'package:forui/forui.dart';

import 'package:plot/style/plot_colors.dart';
import 'text_field.dart';
import 'form_tile_layout.dart';

class InputTile extends StatefulWidget {
  const InputTile({
    required this.label,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.placeholder,
    this.autofocus = false,
    this.focusNode,
    this.highlighted = false,
    super.key,
  });

  /// The label text displayed in the fixed-width prefix (right-aligned).
  final String label;

  /// Optional text controller for the input field.
  final TextEditingController? controller;

  /// Callback fired when the text changes.
  final ValueChanged<String>? onChanged;

  /// Callback fired when Enter is pressed.
  final ValueChanged<String>? onSubmitted;

  /// Optional placeholder text for the input field.
  final String? placeholder;

  /// Whether the input field should autofocus.
  final bool autofocus;

  /// Optional external FocusNode for managing keyboard focus.
  final FocusNode? focusNode;

  /// Whether this tile should show a highlight (for keyboard selection).
  final bool highlighted;

  @override
  State<InputTile> createState() => _InputTileState();
}

class _InputTileState extends State<InputTile> {
  FocusNode? _internalFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode!;

  @override
  void initState() {
    super.initState();
    // Create internal focus node only if external one not provided
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode();
    }
    // Add listener to rebuild when focus changes
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() {}); // Rebuild when focus changes
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    // Only dispose internal focus node
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _focusNode.hasFocus || widget.highlighted;

    return FormTileLayout(
      label: widget.label,
      rightBackgroundColor: context.theme.plotColors.editableBackground,
      isActive: isActive,
      content: TextField(
        controller: widget.controller,
        label: widget.placeholder ?? '',
        style: TextFieldStyle.ghost,
        maxLines: 1,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        autofocus: widget.autofocus,
        focusNode: _focusNode,
      ),
    );
  }
}
