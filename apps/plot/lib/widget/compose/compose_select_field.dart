import 'package:flutter/services.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// A modal-only compose row. Shows [label] in the row's content area with
/// a trailing select chevron, the same hover/focus background as sibling
/// rows, and an [FTooltip] on hover that shows [tooltip] + [shortcut].
/// Tapping the row, or pressing Enter/Space when the row is focused,
/// invokes [onOpen] to surface the picker modal.
class ComposeSelectField extends StatefulWidget {
  const ComposeSelectField({
    super.key,
    required this.tooltip,
    required this.label,
    required this.onOpen,
    this.shortcut,
  });

  /// Hover tooltip label (e.g. "Priority"). Combined with [shortcut] if
  /// set so the user can see the keyboard shortcut.
  final String tooltip;

  /// The value label rendered to the left of the chevron.
  final Widget label;

  /// Invoked on tap, Enter, or Space.
  final Future<void> Function() onOpen;

  /// Optional keyboard shortcut shown in the tooltip.
  final ShortcutActivator? shortcut;

  @override
  State<ComposeSelectField> createState() => _ComposeSelectFieldState();
}

class _ComposeSelectFieldState extends State<ComposeSelectField> {
  final FocusNode _focusNode = FocusNode();
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus != _focused) setState(() => _focused = hasFocus);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onOpen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handleTap() async {
    if (hasPhysicalKeyboard()) _focusNode.requestFocus();
    await widget.onOpen();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final highlighted = _hovered || _focused;
    // Interpolate alpha only — keeping the same RGB on both ends avoids a
    // brief flash of a darker color mid-transition (the Color.lerp from
    // pure black-transparent to editableBackground passes through dim
    // semi-transparent black, which reads as a darker pulse in dark mode).
    final background = highlighted
        ? theme.plotColors.editableBackground
        : theme.plotColors.editableBackground.withValues(alpha: 0);
    final labelStyle = theme.typography.md.copyWith(
      color: theme.plotColors.muted,
    );

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: ComposeFieldRow(
            tooltip: widget.tooltip,
            shortcut: widget.shortcut,
            onTapField: _handleTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: labelStyle,
                    child: IconTheme.merge(
                      data: IconThemeData(
                        color: theme.plotColors.muted,
                        size: theme.iconSizes.sm,
                      ),
                      child: widget.label,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  PlotIcon.verticalExpand,
                  size: theme.iconSizes.xs,
                  color: theme.plotColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
