import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/list_tile.dart';

/// A bottom-of-modal action bar: one primary button plus any secondary peer
/// actions (Archive, Delete, Details, …), auto-grouped from a trailing run of
/// [FormButton]s by `FormModal`.
///
/// Multi-panel (dialog): a single framed row — the primary fills the left
/// (centred, bold accent), secondaries cluster to the right at natural width,
/// hairline vertical dividers between, hover fills the cell.
///
/// Single-panel (bottom sheet): stacked full-width rows, each with a 1px top
/// border, every label centred — primary bold accent, secondaries muted.
///
/// Exposes one focus slot per button so `FormModal`'s linear ↑/↓ navigation
/// steps through the buttons in order (the `FormScheduler` multi-slot pattern).
class FormButtonBar extends FormItem {
  FormButtonBar({required super.key, required this.buttons})
    : assert(buttons.isNotEmpty, 'FormButtonBar needs at least one button'),
      _controllers = List.generate(
        buttons.length,
        (_) => FormButtonController(),
      ),
      super(required: false);

  final List<FormButton> buttons;
  final List<FormButtonController> _controllers;

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => buttons.length;

  /// Index of the first primary button, or null if the bar has no primary.
  int? get primarySubIndex {
    for (var i = 0; i < buttons.length; i++) {
      if (buttons[i].isPrimary) return i;
    }
    return null;
  }

  /// Controller for the primary button (Enter from a text field runs this).
  FormButtonController? get primaryController {
    final i = primarySubIndex;
    return i == null ? null : _controllers[i];
  }

  /// Run the button at [subIndex] (Enter on the highlighted cell).
  Future<void> runSubSlot(int subIndex) async {
    if (subIndex >= 0 && subIndex < _controllers.length) {
      await _controllers[subIndex].run();
    }
  }

  /// Whether the button at [subIndex] is enabled. `skipValidation` buttons
  /// (Archive/Delete) are always enabled; others require a valid form.
  bool isSubSlotEnabled(int subIndex, bool formValid) {
    if (subIndex < 0 || subIndex >= buttons.length) return false;
    return buttons[subIndex].skipValidation || formValid;
  }

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {}

  @override
  bool isValid() => true;

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    // [enabled] carries "is the form valid" from FormModal; per-button enabled
    // is derived from that plus each button's skipValidation flag.
    return _FormButtonBarBody(
      buttons: buttons,
      controllers: _controllers,
      focusNodes: focusNodes,
      highlightedSubIndex: highlightedSubIndex,
      formValid: enabled,
    );
  }
}

class _FormButtonBarBody extends StatelessWidget {
  const _FormButtonBarBody({
    required this.buttons,
    required this.controllers,
    required this.focusNodes,
    required this.highlightedSubIndex,
    required this.formValid,
  });

  final List<FormButton> buttons;
  final List<FormButtonController> controllers;
  final List<FocusNode> focusNodes;
  final int highlightedSubIndex;
  final bool formValid;

  bool _enabled(int i) => buttons[i].skipValidation || formValid;

  /// One tappable button cell, reused by both layouts.
  Widget _tile(BuildContext context, int i) {
    final spec = buttons[i];
    final enabled = _enabled(i);
    final highlighted = highlightedSubIndex == i;
    final colors = context.theme.colors;

    final Color textColor = spec.isPrimary
        ? colors.primary
        : (spec.destructive && highlighted)
        ? colors.destructive
        : context.theme.plotColors.muted;
    final textStyle = context.theme.typography.md.copyWith(
      fontWeight: spec.isPrimary ? FontWeight.bold : FontWeight.normal,
      color: textColor,
    );

    Widget tile = ListTile(
      command: buildWrappedFormButtonCommand(
        context,
        buildCommand: spec.buildCommand,
        skipValidation: spec.skipValidation,
      ),
      // Primary uses the bold `button` style; secondaries stay `item` (normal
      // weight) so they read quieter — hierarchy through weight + colour.
      style: spec.isPrimary ? ListTileStyle.button : ListTileStyle.item,
      centered: true,
      // Symmetric `md` vertical padding: the bar sits flush against the modal's
      // bottom edge (FormModal drops its trailing gap for a bar), so this is
      // the only space below the label — it must match the space above the
      // label (below the top rule) to keep the label vertically centred.
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.md,
      ),
      focusNode: focusNodes.length > i ? focusNodes[i] : null,
      controller: controllers[i].listTileController,
      highlighted: highlighted,
      textStyle: textStyle,
    );

    if (!enabled) {
      tile = Opacity(opacity: 0.5, child: IgnorePointer(child: tile));
    }
    return tile;
  }

  Widget _topBorder(BuildContext context, {required Widget child}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: context.theme.colors.border, width: 1),
          ),
        ),
        child: child,
      );

  Widget _buildStacked(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < buttons.length; i++)
        _topBorder(context, child: _tile(context, i)),
    ],
  );

  Widget _verticalDivider(BuildContext context) =>
      Container(width: 1, color: context.theme.colors.border);

  Widget _buildRow(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i == 0) {
        // Primary (leftmost) fills the remaining width.
        children.add(Expanded(child: _tile(context, i)));
      } else {
        children.add(_verticalDivider(context));
        // Secondaries take only the width they need.
        children.add(IntrinsicWidth(child: _tile(context, i)));
      }
    }
    return _topBorder(
      context,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = context.isMultiPanel
        ? _buildRow(context)
        : _buildStacked(context);
    // Breathing room above the bar's top rule so the field above it isn't
    // flush against the border.
    return Padding(
      padding: EdgeInsets.only(top: context.theme.spacing.md),
      child: content,
    );
  }
}
