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

/// The flat-focus sidebar: drag-reorderable focuses inside a scroll region,
/// then sticky "Add a focus" / Inbox / Everything tiles outside the scroll.
/// Inbox is the root (unfiled threads); Everything is the unscoped feed
/// across the Inbox and every focus.
///
/// Focuses are flat in the new model — no nesting, no top-pinning, no
/// expansion. Reordering writes the existing `order` column via
/// [Order.between]. The full list is always rendered; when it overflows the
/// available height it scrolls behind a top/bottom fade.
class PrioritiesList extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final isLeftPanel =
            PanelPositionProvider.of(context) == HeaderPosition.left;
        // Every sidebar tile (focuses, Add a focus, Inbox, Everything) shares
        // one default weight — regular. Focus tiles and the Inbox go bold
        // when they have active threads; see PriorityWidget / FixedFocusTile.
        final itemStyle =
            (isLeftPanel
                    ? context.theme.typography.sm
                    : context.theme.typography.md)
                .copyWith(fontWeight: FontWeight.w400);
        // In the left panel the list floats on the tinted frame with
        // horizontal insets — round the hover/selection highlights so they
        // read as discrete pills. Single-panel mode goes edge-to-edge, so
        // keep it rectangular. Tiles outside the squircles render monochrome
        // at rest and reintroduce focus colour on hover/selection.
        final BorderRadius? itemBorderRadius = isLeftPanel
            ? BorderRadius.circular(6)
            : null;
        final bool monochrome = isLeftPanel;

        TextStyle focusStyle(Priority p) => itemStyle.copyWith(
          color: p.archivedAt != null
              ? context.theme.colors.mutedForeground
              : context.colour.colours.fromTheme(
                  p.displayColor,
                  muted: !monochrome && !p.unread,
                ),
        );

        // Scrollable focuses, followed by "Add a focus" (the focus-list
        // tail) and the empty-state hint when there are no focuses yet. The
        // fade communicates that this region scrolls independently of the
        // sticky tiles below. Alpha-mask mode so the edges fade into the
        // tinted frame gradient instead of painting a darker card-shaped
        // fill over it.
        final scrollable = ScrollEdgeFade(
          transparent: true,
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // md top padding sets the panel apart from the agenda above it.
                SizedBox(height: context.theme.spacing.md),
                ReorderableListView<Priority>(
                  list: focuses,
                  shrinkWrap: true,
                  // Key on `id` (not the instance) so a row survives
                  // unread/active churn without remounting.
                  keyExtractor: (p) => ValueKey(p.id),
                  itemBuilder: (context, priority, reorderableIndex) =>
                      PriorityWidget(
                        key: ValueKey('focus-${priority.id}'),
                        priority: priority,
                        monochrome: monochrome,
                        selected: !everything && selected?.id == priority.id,
                        selectedBorder: true,
                        borderRadius: itemBorderRadius,
                        textStyle: focusStyle(priority),
                        unread: priority.unread ? true : null,
                        reorderableIndex: reorderableIndex,
                      ),
                  onReorder: (oldIndex, newIndex) =>
                      _onReorderFocus(focuses, oldIndex, newIndex),
                ),
                if (focuses.isEmpty)
                  Text(
                    'Add a focus to gather work related to a role, project, or activity.',
                    style: TextStyle(
                      color: context.theme.plotColors.veryMuted,
                      fontSize: context.theme.typography.sm.fontSize,
                    ),
                  ),
                // "Add a focus" closes off the focus list — it scrolls with
                // the focuses, not pinned with Inbox/Everything below.
                ListTile(
                  command: CommandWrapper(
                    AddFocus(),
                    icon: Value(null),
                    title: 'Add a focus',
                  ),
                  icon: PlotIcon.add,
                  iconOnly: true,
                  muted: true,
                  // Same hover treatment as the header icon buttons: no
                  // rounded background pill, just the icon/text shift.
                  highlightColor: monochrome ? const Color(0x00000000) : null,
                  borderRadius: monochrome ? null : itemBorderRadius,
                ),
                SizedBox(height: context.theme.spacing.md),
              ],
            ),
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: layoutState.multiPanel
              ? MainAxisSize.min
              : MainAxisSize.max,
          children: [
            // Flexible (not Expanded) so the scroll region shrinks to its
            // natural height when there's room and only takes the remaining
            // space — leaving the sticky tiles at the bottom — when focuses
            // would otherwise overflow.
            Flexible(child: scrollable),

            // Inbox + Everything stay pinned below the scrollable focuses
            // so they remain reachable no matter how long the focus list
            // grows. "Add a focus" lives inside the scroll, as the tail of
            // the focus list.

            // Fixed Inbox tile — the root focus, holding unfiled threads.
            // Not reorderable, not archivable. Always labelled "Inbox": it
            // is a fixed, semantic tile (the server projects the root as
            // "Inbox" at apiVersion >= 4, but older synced roots may still
            // carry the legacy "Everything" title).
            FixedFocusTile(
              title: 'Inbox',
              icon: PlotIcon.inbox,
              isSelected: !everything && selected?.id == root.id,
              command: ChangeCurrentPriority(root),
              menuCommand: ShowPriorityCommands(root),
              hasUnread: root.unread,
              // Bold when the Inbox has active threads, like a focus tile.
              active: root.active,
              borderRadius: itemBorderRadius,
              textStyle: itemStyle,
              monochrome: monochrome,
            ),

            // Fixed Everything tile — the unscoped feed across the Inbox and
            // every focus. Rooted on the root with Everything mode on.
            FixedFocusTile(
              title: 'Everything',
              icon: PlotIcon.inboxes,
              isSelected: everything,
              command: ChangeCurrentPriority(root, everything: true),
              menuCommand: null,
              // Everything is the unscoped feed — it never carries its own
              // unread indicator and never goes bold.
              hasUnread: false,
              active: false,
              borderRadius: itemBorderRadius,
              textStyle: itemStyle,
              monochrome: monochrome,
            ),
          ],
        );
      },
    );
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
class FixedFocusTile extends StatefulWidget {
  final String title;

  /// The leading icon (an inbox glyph for Inbox, inboxes for Everything).
  final IconData icon;
  final bool isSelected;

  /// Run on tap.
  final Command command;

  /// Optional hover/long-press menu. Null for the synthetic Everything view.
  final Command? menuCommand;
  final bool hasUnread;

  /// When true, render the title bold — matching the focus tiles' active-
  /// threads treatment. Everything always passes false.
  final bool active;
  final BorderRadius? borderRadius;
  final TextStyle textStyle;
  final bool monochrome;

  const FixedFocusTile({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.command,
    required this.menuCommand,
    required this.hasUnread,
    required this.active,
    required this.borderRadius,
    required this.textStyle,
    required this.monochrome,
    super.key,
  });

  @override
  State<FixedFocusTile> createState() => FixedFocusTileState();
}

class FixedFocusTileState extends State<FixedFocusTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isHovered;
    // Inbox and Everything are fixed, semantic tiles — both render in the
    // Resolution brand colour (index 7) regardless of the root's own colour.
    const tileColor = ThemeColor.defaultColor();
    final restingColor = context.colour.muted;
    // Muted at rest, like the focus tiles; the Resolution colour shows when
    // the tile is bold (active threads — Inbox only) or on hover/selection.
    final labelColor = widget.monochrome && !isActive && !widget.active
        ? restingColor
        : context.colour.colours.fromTheme(tileColor);
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(tileColor)
        : null;
    // Matching selection ring for the fixed tiles, in the Resolution/brand
    // colour they already render in.
    final ringColor = widget.monochrome
        ? context.colour.colours.borderFromTheme(tileColor)
        : null;

    final menuCommand = widget.menuCommand;

    final listTile = ListTile(
      command: widget.command,
      // Menu opens via long-left swipe on touch (see wrapper below); long-
      // press is reserved for reorder drag elsewhere.
      longPressCommand: null,
      selected: widget.isSelected,
      selectedColor: accentBg,
      selectedBorderColor: ringColor,
      highlightColor: accentBg,
      borderRadius: widget.borderRadius,
      onHover: (hovered) {
        if (mounted && _isHovered != hovered) {
          setState(() => _isHovered = hovered);
        }
      },
      leadingBuilder: (isHovered, hasFocus) {
        final iconSize = context.theme.iconSizes.base;
        // Shared sidebar leading slot (md inset on either side of the icon —
        // see sidebarLeading / PriorityWidget). Icon shares the title's colour
        // so the two always match.
        return sidebarLeading(
          context,
          Icon(widget.icon, size: iconSize, color: labelColor),
        );
      },
      // Title in the accent colour, with the unread dot trailing it (kept
      // outside the Flexible so it survives title truncation). Bold when the
      // tile has active threads (Inbox only — Everything never bolds).
      body: Row(
        children: [
          Flexible(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              // No explicit line height: natural font metrics centre the cap
              // in the line box so the label co-centres with the leading icon.
              // A tight `height: 1` leaves the text top-aligned against it.
              style: widget.textStyle.copyWith(
                color: labelColor,
                fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (widget.hasUnread)
            Padding(
              padding: EdgeInsets.only(left: context.theme.spacing.sm),
              child: const PriorityNotification(unread: true, color: tileColor),
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
