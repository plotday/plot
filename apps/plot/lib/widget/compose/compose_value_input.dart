import 'package:flutter/material.dart' show OutlineInputBorder;

import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// "Ghost" text field used inside priority / connection compose rows.
///
/// When unfocused it renders [value] (if non-null) or [hint] as muted /
/// very-muted text — visually a plain label. When focused it swaps in a
/// borderless [FTextField] driven by [controller] so the user can filter
/// the popover dropdown by typing. Both states share the same height so
/// the row doesn't reflow on focus.
///
/// Selection (choosing an item, pressing Enter) and dismissal (Escape /
/// blur) are owned by the parent field — this widget only handles the
/// visual swap and forwards the [TextEditingController] to the input.
class ComposeValueInput extends StatefulWidget {
  const ComposeValueInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    this.value,
    this.readOnly = false,
  });

  /// Text controller for the filtering input. The parent should clear this
  /// when the user commits a selection.
  final TextEditingController controller;

  /// Focus node owned by the parent; the input listens to it to flip
  /// between label and editable modes.
  final FocusNode focusNode;

  /// Placeholder text shown when [value] is null and the field is
  /// unfocused. Also used as the input's hint when focused.
  final String hint;

  /// Rich widget shown when the field is unfocused and a value is set.
  /// When null, [hint] is shown instead.
  final Widget? value;

  /// When true (touch platforms), the text field is readOnly — the row's
  /// tap handler should open a modal instead of the inline input.
  final bool readOnly;

  @override
  State<ComposeValueInput> createState() => _ComposeValueInputState();
}

class _ComposeValueInputState extends State<ComposeValueInput> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(ComposeValueInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    final next = widget.focusNode.hasFocus;
    if (next != _focused) setState(() => _focused = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final showLabel = !_focused || widget.readOnly;

    // The visible label / placeholder. Sits in a [Stack] under the input
    // so both have identical height — eliminates row jumps on focus.
    // Labels use the same typography size as the FTextField's content text
    // (theme default = md) so the row doesn't visibly grow when focus
    // swaps the label for the input. Only color differs: muted for values,
    // veryMuted for the empty hint.
    final labelStyle = theme.typography.md;
    final Widget label;
    if (widget.value != null) {
      label = DefaultTextStyle.merge(
        style: labelStyle.copyWith(color: theme.plotColors.muted),
        child: IconTheme.merge(
          data: IconThemeData(color: theme.plotColors.muted),
          child: widget.value!,
        ),
      );
    } else {
      label = Text(
        widget.hint,
        style: labelStyle.copyWith(color: theme.plotColors.veryMuted),
      );
    }

    // SizedBox(width: double.infinity) forces the trigger to fill the
    // available horizontal space; without it the Stack shrinks to its
    // visible child's intrinsic width, which makes the [Dropdown] anchor
    // measure a narrow trigger and render a too-thin popover.
    return SizedBox(
      width: double.infinity,
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          // Always-present text field — hidden behind the label when
          // unfocused so its FocusNode stays attached and the parent can
          // call requestFocus on it.
          Offstage(
            offstage: showLabel,
            child: FTextField(
              builder: fieldSelectionBuilder,
              control: .managed(controller: widget.controller),
              focusNode: widget.focusNode,
              readOnly: widget.readOnly,
              hint: widget.hint,
              style: _ghostFieldStyle(theme),
            ),
          ),
          if (showLabel)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: label,
            ),
        ],
      ),
    );
  }
}

/// Strips FTextField chrome (border, background-driven padding) and uses
/// the compose typography weights: muted value text, very-muted hint.
FTextFieldStyleDelta ghostFieldStyle(BuildContext context) =>
    _ghostFieldStyle(context.theme);

FTextFieldStyleDelta _ghostFieldStyle(FThemeData theme) {
  return FTextFieldStyleDelta.delta(
    contentPadding: EdgeInsetsGeometryDelta.value(
      EdgeInsets.symmetric(horizontal: 0, vertical: isMobilePlatform() ? 10 : 6),
    ),
    // The default style fills the focused field with editableBackground,
    // which overpaints the compose surface's single bottom border. Keep
    // the field transparent in every variant so the parent decoration
    // shows through.
    color: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.all(const Color(0x00000000)),
    ]),
    // gapPadding: 0 — Material 3's InputDecorator adds border.gapPadding
    // (default 4.0) to the input's start padding via `inputGap`, which
    // shifts the field's text 4px right of the placeholder and the
    // leading edge of every other compose row.
    border: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.all(
        const OutlineInputBorder(
          borderSide: BorderSide(width: 0, style: BorderStyle.none),
          gapPadding: 0,
        ),
      ),
    ]),
  );
}
