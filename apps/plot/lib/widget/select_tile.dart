import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'icon.dart';
import 'form_tile_layout.dart';

class SelectTile extends StatefulWidget {
  const SelectTile({
    required this.label,
    required this.onSelect,
    this.value,
    this.leading,
    this.placeholder,
    this.autofocus = false,
    this.focusNode,
    this.highlighted = false,
    this.enabled = true,
    super.key,
  });

  /// The label text displayed in the fixed-width prefix (right-aligned).
  final String label;

  /// The current selected value to display.
  final String? value;

  /// Optional leading widget (e.g., a color dot).
  final Widget? leading;

  /// Optional placeholder text when no value is selected.
  final String? placeholder;

  /// Callback fired when the field is activated (tap or Enter).
  final VoidCallback onSelect;

  /// Whether the field should autofocus.
  final bool autofocus;

  /// Optional external FocusNode for managing keyboard focus.
  final FocusNode? focusNode;

  /// Whether this tile should show a highlight (for keyboard selection).
  final bool highlighted;

  /// Whether the field is enabled and can receive focus/interaction.
  final bool enabled;

  @override
  State<SelectTile> createState() => _SelectTileState();
}

class _SelectTileState extends State<SelectTile> {
  FocusNode? _internalFocusNode;
  bool _isHovered = false;

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

    // Autofocus if requested
    if (widget.autofocus && widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focusNode.requestFocus();
      });
    }
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

  void _handleActivate() {
    if (widget.enabled) {
      widget.onSelect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = widget.value != null && widget.value!.isNotEmpty;
    final displayText = hasValue ? widget.value! : (widget.placeholder ?? '');
    final isHighlighted =
        widget.enabled &&
        (_focusNode.hasFocus || _isHovered || widget.highlighted);

    return FocusableActionDetector(
      focusNode: _focusNode,
      enabled: widget.enabled,
      child: FormTileLayout(
        label: widget.label,
        rightBackgroundColor: isHighlighted
            ? context.theme.colors.secondary
            : null,
        isActive: isHighlighted,
        content: GestureDetector(
          onTap: widget.enabled ? _handleActivate : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.basic,
            onEnter: widget.enabled
                ? (_) {
                    setState(() {
                      _isHovered = true;
                    });
                  }
                : null,
            onExit: widget.enabled
                ? (_) {
                    setState(() {
                      _isHovered = false;
                    });
                  }
                : null,
            child: Row(
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  SizedBox(width: context.theme.spacing.md),
                ],
                Expanded(
                  child: Text(
                    displayText,
                    style: context.theme.typography.base.copyWith(
                      color: widget.enabled
                          ? (hasValue
                                ? context.theme.colors.foreground
                                : context.theme.plotColors.muted)
                          : context.theme.plotColors.muted,
                    ),
                  ),
                ),
                Icon(
                  PlotIcon.verticalExpand,
                  size: context.theme.iconSizes.xs,
                  color: context.theme.plotColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
