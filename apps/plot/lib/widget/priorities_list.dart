import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/widget.dart';

/// The flat-focus sidebar: drag-reorderable focuses, then a fixed Inbox tile
/// (the root — unfiled threads), then a fixed Everything tile (the unscoped
/// feed across the Inbox and every focus), then "Add a focus".
///
/// Focuses are flat in the new model — no nesting, no top-pinning, no
/// expansion. Reordering writes the existing `order` column via
/// [Order.between]. A "More" affordance truncates a long list down to the
/// active/unread focuses.
class PrioritiesList extends StatefulWidget {
  final List<Priority> focuses;
  final Priority root;
  final Priority? selected;

  /// True when the synthetic "Everything" feed is the active view. Both Inbox
  /// and Everything are rooted on [root], so the highlight is driven by this
  /// flag (from `NowBloc.everything`) rather than by [selected] alone.
  final bool everything;

  PrioritiesList({
    super.key,
    required this.root,
    required List<Priority> priorities,
    this.selected,
    this.everything = false,
  }) : focuses = (priorities.where((p) => !p.root).toList()..sort(_byOrder));

  static int _byOrder(Priority a, Priority b) {
    final c = a.order.value.compareTo(b.order.value);
    return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
  }

  @override
  State<PrioritiesList> createState() => _PrioritiesListState();
}

class _PrioritiesListState extends State<PrioritiesList> {
  /// When false, the focus list is truncated to active/unread focuses (plus
  /// enough to reach [_truncateAt]); tapping "More" reveals the rest.
  bool _showAll = false;

  /// Show every focus when there are at most this many; truncate beyond it.
  static const int _truncateAt = 5;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final isLeftPanel =
            PanelPositionProvider.of(context) == HeaderPosition.left;
        final itemStyle =
            (isLeftPanel
                    ? context.theme.typography.sm
                    : context.theme.typography.md)
                .copyWith(fontWeight: FontWeight.w500);
        // In the left panel the list floats on the tinted frame with
        // horizontal insets — round the hover/selection highlights so they
        // read as discrete pills. Single-panel mode goes edge-to-edge, so
        // keep it rectangular. Tiles outside the squircles render monochrome
        // at rest and reintroduce focus colour on hover/selection.
        final BorderRadius? itemBorderRadius = isLeftPanel
            ? BorderRadius.circular(6)
            : null;
        final bool monochrome = isLeftPanel;

        final focuses = widget.focuses;
        final visible = _visibleFocuses(focuses);
        final truncated = visible.length < focuses.length;

        TextStyle focusStyle(Priority p) => itemStyle.copyWith(
          color: p.archivedAt != null
              ? context.theme.colors.mutedForeground
              : context.colour.colours.fromTheme(
                  p.displayColor,
                  muted: !monochrome && !p.unread,
                ),
        );

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // lg top padding sets the panel apart from the agenda above it.
              SizedBox(height: context.theme.spacing.md),

              // Flat, drag-reorderable focuses.
              ReorderableListView<Priority>(
                list: visible,
                shrinkWrap: true,
                // Key on `id` (not the instance) so a row survives
                // unread/active churn without remounting.
                keyExtractor: (p) => ValueKey(p.id),
                itemBuilder: (context, priority, reorderableIndex) =>
                    PriorityWidget(
                      key: ValueKey('focus-${priority.id}'),
                      priority: priority,
                      monochrome: monochrome,
                      selected:
                          !widget.everything &&
                          widget.selected?.id == priority.id,
                      selectedBorder: true,
                      borderRadius: itemBorderRadius,
                      textStyle: focusStyle(priority),
                      unread: priority.unread ? true : null,
                      reorderableIndex: reorderableIndex,
                    ),
                onReorder: (oldIndex, newIndex) =>
                    _onReorderFocus(visible, oldIndex, newIndex),
              ),

              if (truncated)
                _ShowMoreItem(
                  indentLevel: 0,
                  textStyle: itemStyle,
                  onTap: () => setState(() => _showAll = true),
                ),

              // "Add a focus" sits directly above the fixed Inbox/Everything
              // tiles, closing off the reorderable focus list.
              ListTile(
                command: CommandWrapper(
                  NewFocus(),
                  icon: Value(null),
                  title: 'Add a focus',
                ),
                icon: PlotIcon.add,
                iconOnly: true,
                muted: true,
                // Same hover treatment as the header icon buttons: no rounded
                // background pill, just the icon/text shift.
                highlightColor: monochrome ? const Color(0x00000000) : null,
                borderRadius: monochrome ? null : itemBorderRadius,
              ),

              // Fixed Inbox tile — the root focus, holding unfiled threads.
              // Not reorderable, not archivable. Always labelled "Inbox": it
              // is a fixed, semantic tile (the server projects the root as
              // "Inbox" at apiVersion >= 4, but older synced roots may still
              // carry the legacy "Everything" title).
              _FixedFocusTile(
                title: 'Inbox',
                icon: PlotIcon.inbox,
                isSelected:
                    !widget.everything && widget.selected?.id == widget.root.id,
                command: ChangeCurrentPriority(widget.root),
                menuCommand: ShowPriorityCommands(widget.root),
                hasUnread: widget.root.unread,
                borderRadius: itemBorderRadius,
                textStyle: itemStyle,
                monochrome: monochrome,
              ),

              // Fixed Everything tile — the unscoped feed across the Inbox and
              // every focus. Rooted on the root with Everything mode on.
              _FixedFocusTile(
                title: 'Everything',
                icon: PlotIcon.inboxes,
                isSelected: widget.everything,
                command: ChangeCurrentPriority(widget.root, everything: true),
                menuCommand: null,
                // Everything is the unscoped feed — it never carries its own
                // unread indicator.
                hasUnread: false,
                borderRadius: itemBorderRadius,
                textStyle: itemStyle,
                monochrome: monochrome,
              ),

              if (focuses.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.contentPaddingH,
                    vertical: context.theme.spacing.xl,
                  ),
                  child: Text(
                    'Focuses put your work in context. Add your roles, goals, and projects.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.theme.plotColors.veryMuted,
                      fontSize: context.theme.typography.sm.fontSize,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The focuses to render: every focus when [_showAll] is set or the list is
  /// short; otherwise the active/unread focuses always, filling the remaining
  /// slots by order, with the rest collapsed behind "More" (preserving the
  /// natural order).
  List<Priority> _visibleFocuses(List<Priority> focuses) {
    if (_showAll || focuses.length <= _truncateAt) return focuses;
    final keep = <Priority>{};
    for (final p in focuses) {
      if (p.active || p.unread) keep.add(p);
    }
    for (final p in focuses) {
      if (keep.length >= _truncateAt) break;
      keep.add(p);
    }
    return focuses.where(keep.contains).toList();
  }

  Future<void> _onReorderFocus(
    List<Priority> peers,
    int oldIndex,
    int newIndex,
  ) async {
    final previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
    final nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

    final current = peers[oldIndex];
    Priority? previous;
    if (previousIndex >= 0) previous = peers[previousIndex];
    Priority? next;
    if (nextIndex < peers.length) next = peers[nextIndex];

    await current
        .copyWith(
          order: Order.between(previous?.order, next?.order),
          pending: const Value(2),
        )
        .save();
  }
}

/// A fixed (non-reorderable) sidebar tile for the Inbox and Everything views.
/// Mirrors [PriorityWidget]'s left-panel treatment — monochrome at rest,
/// colour on hover/selection — but without the reorder handle, weekly-total
/// chip, or expansion affordances. Both tiles render in the fixed Resolution
/// brand colour rather than the root's own colour.
class _FixedFocusTile extends StatefulWidget {
  final String title;

  /// The leading icon (an inbox glyph for Inbox, inboxes for Everything).
  final IconData icon;
  final bool isSelected;

  /// Run on tap.
  final Command command;

  /// Optional hover/long-press menu. Null for the synthetic Everything view.
  final Command? menuCommand;
  final bool hasUnread;
  final BorderRadius? borderRadius;
  final TextStyle textStyle;
  final bool monochrome;

  const _FixedFocusTile({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.command,
    required this.menuCommand,
    required this.hasUnread,
    required this.borderRadius,
    required this.textStyle,
    required this.monochrome,
  });

  @override
  State<_FixedFocusTile> createState() => _FixedFocusTileState();
}

class _FixedFocusTileState extends State<_FixedFocusTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isHovered;
    // Inbox and Everything are fixed, semantic tiles — both render in the
    // Resolution brand colour (index 7) regardless of the root's own colour.
    const tileColor = ThemeColor.defaultColor();
    final accent = context.colour.colours.fromTheme(
      tileColor,
      muted: !widget.monochrome && !widget.hasUnread,
    );
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(tileColor)
        : null;
    final restingColor = context.colour.muted;
    final indicatorColor = widget.monochrome && !isActive
        ? restingColor
        : context.colour.colours.fromTheme(tileColor);

    final menuCommand = widget.menuCommand;

    final listTile = ListTile(
      command: widget.command,
      // Menu opens via long-left swipe on touch (see wrapper below); long-
      // press is reserved for reorder drag elsewhere.
      longPressCommand: null,
      selected: widget.isSelected,
      selectedColor: accentBg,
      highlightColor: accentBg,
      borderRadius: widget.borderRadius,
      onHover: (hovered) {
        if (mounted && _isHovered != hovered) {
          setState(() => _isHovered = hovered);
        }
      },
      leadingBuilder: (isHovered, hasFocus) {
        final iconSize = context.theme.iconSizes.base;
        // Standard command-tile leading metrics: 20px from the panel edge,
        // then a 12px gap to the title (mirrors PriorityWidget).
        return Padding(
          padding: const EdgeInsets.only(left: 20, right: 12),
          child: SizedBox.square(
            dimension: iconSize,
            child: Icon(widget.icon, size: iconSize, color: indicatorColor),
          ),
        );
      },
      // Title in the accent colour, with the unread dot trailing it (kept
      // outside the Flexible so it survives title truncation).
      body: Row(
        children: [
          Flexible(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: widget.textStyle.copyWith(color: accent, height: 1),
            ),
          ),
          if (widget.hasUnread)
            Padding(
              padding: EdgeInsets.only(left: context.theme.spacing.sm),
              child: const PriorityNotification(
                unread: true,
                color: tileColor,
              ),
            ),
        ],
      ),
      // Always reserve the menu-button slot height so the Everything tile
      // (which has no menu) matches the Inbox row height — and both match
      // the focus tiles. Mirrors PriorityWidget's buttonSlotHeight.
      trailingBuilder: (isHovered, hasFocus) {
        final buttonSlotHeight = context.theme.iconSizes.base * 2;
        return SizedBox(
          height: buttonSlotHeight,
          child: menuCommand == null
              ? null
              : Center(
                  child: Padding(
                    padding: EdgeInsets.only(right: context.theme.spacing.sm),
                    child: (isHovered || hasFocus)
                        ? Button.icon(menuCommand)
                        : Visibility(
                            visible: false,
                            maintainSize: true,
                            maintainAnimation: true,
                            maintainState: true,
                            child: Button.icon(menuCommand),
                          ),
                  ),
                ),
        );
      },
    );

    if (menuCommand == null || hasPhysicalKeyboard()) return listTile;

    // Touch: open the menu via a long-left swipe.
    return Swipeable(
      key: ValueKey('fixed-${widget.title}'),
      endLongCommand: menuCommand,
      child: listTile,
    );
  }
}

class _ShowMoreItem extends StatefulWidget {
  final int indentLevel;
  final VoidCallback onTap;
  final TextStyle? textStyle;

  const _ShowMoreItem({
    required this.indentLevel,
    required this.onTap,
    this.textStyle,
  });

  @override
  State<_ShowMoreItem> createState() => _ShowMoreItemState();
}

class _ShowMoreItemState extends State<_ShowMoreItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: EdgeInsets.only(
            left: widget.indentLevel * (16 + context.theme.spacing.sm),
          ),
          child: Row(
            children: [
              // Match PriorityWidget leading: 20px inset + 16px icon + 12px gap.
              const SizedBox(width: 20 + 16 + 12),
              Expanded(
                child: Padding(
                  padding: context.theme.spacing.paddingSm.copyWith(
                    left: 0,
                    right: 0,
                  ),
                  child: Text(
                    'More…',
                    style: (widget.textStyle ?? context.theme.typography.sm)
                        .copyWith(
                          color: _isHovered
                              ? context.theme.colors.foreground
                              : context.theme.colors.mutedForeground,
                        ),
                  ),
                ),
              ),
              SizedBox(width: 20),
            ],
          ),
        ),
      ),
    );
  }
}
