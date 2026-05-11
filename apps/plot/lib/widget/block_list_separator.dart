import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/agenda_model.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/infinite_list.dart';

/// Returns the priority accent for [item] when it should style the
/// adjacent divider as "selected", otherwise `null`. The activity feed
/// returns the thread's accent only for the currently-opened thread; the
/// agenda returns the block priority's accent for every item belonging
/// to the user's current priority.
typedef SelectedAccentResolver = Color? Function(AgendaItem item);

/// Whether [item] participates in hover/focus highlight on its
/// flanking dividers. Returns false for items where a brighter divider
/// would read as an out-of-place affordance (e.g. block headers, gap
/// markers, date headers).
typedef HoverHighlightTest = bool Function(AgendaItem item);

/// Returns the drag-system id [item] should be compared against to
/// decide whether the divider above it must collapse — null when no
/// match is meaningful for the item.
typedef DragSourceIdResolver = String? Function(AgendaItem item);

/// Always 1px tall for stable layout. Default renders the standard
/// border color; selection paints the priority accent at low alpha;
/// hover/focus paints a brighter version of the border color. While
/// the next item's block is the active drag source (and the source
/// has logically moved into a drop slot) the separator collapses so
/// the source's at-rest layout slot doesn't leave a residual 1px line.
///
/// Shared between PriorityPage's activity feed and the universal
/// agenda — both lists need identical divider styling and drag-aware
/// behavior, so divergence here would surface as visible mismatch.
class BlockListSeparator extends StatelessWidget {
  const BlockListSeparator({
    required this.prev,
    required this.next,
    required this.controller,
    required this.dragController,
    required this.index,
    required this.selectedAccent,
    required this.canHighlight,
    required this.dragSourceId,
    super.key,
  });

  final AgendaItem? prev;
  final AgendaItem? next;
  final InfiniteListController controller;
  final BlockDragController? dragController;

  /// Index of the item the separator sits above. Used to read the
  /// controller's hover/focus state for the flanking rows.
  final int index;

  final SelectedAccentResolver selectedAccent;
  final HoverHighlightTest canHighlight;
  final DragSourceIdResolver dragSourceId;

  @override
  Widget build(BuildContext context) {
    final dc = dragController;
    if (dc == null) {
      return _buildSeparator(context, dragging: false, sourceVisible: true);
    }
    return ListenableBuilder(
      listenable: dc,
      builder: (context, _) => _buildSeparator(
        context,
        dragging: dc.isDragging,
        sourceVisible: dc.isSourceVisible,
        draggingBlockId: dc.draggingBlockId,
      ),
    );
  }

  Widget _buildSeparator(
    BuildContext context, {
    required bool dragging,
    required bool sourceVisible,
    String? draggingBlockId,
  }) {
    final borderColor = context.theme.colors.border;
    final bg = context.colour.background;
    final baseBorder = Color.alphaBlend(borderColor, bg);

    final next = this.next;
    final prev = this.prev;

    // Hide the separator above the dragged source's at-rest layout
    // slot once the source has logically moved into an active drop
    // zone — without this the row vanishes but the surrounding 1px
    // line remains, leaving a visible 1px height shift.
    final nextSourceId = next != null ? dragSourceId(next) : null;
    final shouldHide = draggingBlockId != null &&
        nextSourceId == draggingBlockId &&
        !sourceVisible;

    Widget separator;

    final prevAccent = prev != null ? selectedAccent(prev) : null;
    final nextAccent = next != null ? selectedAccent(next) : null;
    final accent = prevAccent ?? nextAccent;
    if (accent != null) {
      // Selection: priority accent at low alpha blended into the
      // border color. Painted regardless of hover/focus or drag —
      // selection is a persistent state, not an interaction
      // affordance.
      final tinted = accent.withValues(alpha: 0.3);
      separator = Container(
        height: 1,
        color: Color.alphaBlend(tinted, baseBorder),
      );
    } else {
      // Hover/focus highlight on either flank — only when the row's
      // type opts in, and never while a block-level drag is in
      // progress (block drag drives its own drop indicator).
      final draggingIndex = controller.draggingIndex;
      final hovered = controller.hoveredIndex;
      final focused = controller.focusedIndex;
      final prevHighlighted = prev != null &&
          !dragging &&
          canHighlight(prev) &&
          (hovered == index - 1 || focused == index - 1) &&
          draggingIndex != index - 1;
      final nextHighlighted = next != null &&
          !dragging &&
          canHighlight(next) &&
          (hovered == index || focused == index) &&
          draggingIndex != index;
      if (prevHighlighted || nextHighlighted) {
        final bright = borderColor.withValues(
          alpha: (borderColor.a * 2).clamp(0.0, 1.0),
        );
        separator = Container(
          height: 1,
          color: Color.alphaBlend(bright, bg),
        );
      } else {
        // Default: transparent for the first item (avoids a double
        // line above any leading section header), otherwise the
        // standard border color.
        separator = Container(
          height: 1,
          color: prev == null ? bg : baseBorder,
        );
      }
    }

    return AnimatedSize(
      duration: kBlockBoundaryAnimDuration,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: shouldHide ? const SizedBox.shrink() : separator,
    );
  }
}
