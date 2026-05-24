import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// Inline title input for the NewThreadPage row stack. Collapsed shows a
/// sparkles/pen chip; expanded shows a single-line text field.
class InlineTitleInput extends StatefulWidget {
  const InlineTitleInput({
    super.key,
    required this.title,
    required this.onChanged,
  });

  /// Current title (null = no title set).
  final String? title;

  /// Persist a new value. `null` clears.
  final Future<void> Function(String? next) onChanged;

  @override
  State<InlineTitleInput> createState() => InlineTitleInputState();
}

class InlineTitleInputState extends State<InlineTitleInput> {
  bool _expanded = false;
  bool _hovered = false;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title ?? '');
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(InlineTitleInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_expanded && widget.title != oldWidget.title) {
      _controller.text = widget.title ?? '';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Expand and focus. Called by the chip on tap and by external code
  /// (e.g. ⌘⇧H shortcut on NewThreadPage).
  void focus() {
    if (!_expanded) {
      setState(() {
        _expanded = true;
        _controller.text = widget.title ?? '';
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus && _expanded) {
      _commit(_controller.text);
    }
  }

  Future<void> _commit(String value) async {
    if (!_expanded) return; // Already committing; ignore re-entry.
    setState(() => _expanded = false);
    final trimmed = value.trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (next != widget.title) {
      await widget.onChanged(next);
    }
  }

  void _cancel() {
    _controller.text = widget.title ?? '';
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    // Reserve a constant height equal to the expanded input's natural height
    // so toggling between chip and input never shifts the editor below. The
    // chip is top-aligned so the visible gap above it matches the spacing
    // between every other row; the extra space below the chip is consumed
    // by the input when expanded.
    return SizedBox(
      height: 44,
      child: Align(
        alignment: Alignment.topLeft,
        child: _expanded ? _buildExpanded(context) : _buildChip(context),
      ),
    );
  }

  Widget _buildChip(BuildContext context) {
    final hasTitle = (widget.title ?? '').isNotEmpty;
    final IconData icon;
    final String label;
    final Color color;
    if (hasTitle) {
      icon = FontAwesomeIcons.pen;
      label = widget.title!;
      color = _hovered
          ? context.theme.colors.foreground
          : context.theme.plotColors.muted;
    } else if (_hovered) {
      icon = FontAwesomeIcons.pen;
      label = 'Title';
      color = context.theme.colors.foreground;
    } else {
      icon = PlotIcon.sparkles;
      label = 'Title';
      color = context.theme.plotColors.veryMuted;
    }

    final fontSize = context.theme.typography.sm.fontSize ?? 14.0;

    final button = FButton(
      onPress: focus,
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
        padding: EdgeInsets.zero,
      ),
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          FaIcon(icon, size: fontSize, color: color),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.sm.copyWith(
                color: color,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: button,
    );

    if (!hasPhysicalKeyboard()) return hoverable;
    return FTooltip(
      tipBuilder: (context, controller) => Text(
        hasTitle ? 'Edit title' : 'Set title',
      ),
      child: hoverable,
    );
  }

  Widget _buildExpanded(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, minWidth: 200),
        child: FTextField(
          control: .managed(controller: _controller),
          focusNode: _focusNode,
          hint: 'Title',
          onSubmit: _commit,
          textInputAction: TextInputAction.done,
        ),
      ),
    );
  }
}
