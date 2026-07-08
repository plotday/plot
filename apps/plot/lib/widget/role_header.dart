import 'package:flutter/material.dart' as material;

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/sidebar.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// A collapsible role header row in the accordion sidebar. Renders the role's
/// name as an **uppercase eyebrow** ([eyebrowLabelStyle]) — small, widely
/// tracked, in the role's colour — so a role reads as a section heading a level
/// above its focuses. The name always renders at the heavier weight (w600), so
/// a role stays a prominent heading whether it's expanded or collapsed and
/// whether or not any of its focuses are active. A **collapsed** header also
/// carries a faint trailing chevron (a quiet "open me" cue) that cross-fades to
/// the hover-revealed "…" menu ([ShowRoleCommands]). Tapping a **collapsed**
/// header runs [onTap] (the left panel selects the role's first focus;
/// single-panel just discloses them); the **expanded** header is inert — no
/// chevron, no hover pill. The remaining status signals are reverse-inherited
/// from its child focuses:
///
/// - **full colour** (rather than muted at rest) when any child focus is
///   active, and
/// - an unread **dot** ([PriorityNotification]) when **collapsed** and any
///   child focus is unread.
///
/// Stateless except for local hover state (mirrors [PriorityWidget]); all Bloc
/// state is passed in by the page.
class RoleHeader extends StatefulWidget {
  const RoleHeader({
    required this.role,
    required this.expanded,
    required this.childFocuses,
    required this.onTap,
    this.monochrome = false,
    this.borderRadius,
    this.reorderableIndex,
    this.roomy = false,
    super.key,
  });

  final Role role;

  /// The header's index in the outer (role) reorderable list. The accordion
  /// runs that list in handle-only mode so the role drag is scoped to the
  /// header — never the expanded role's inner focus list. When non-null:
  /// desktop drags the header on pointer-down (via [ListTile.reorderableIndex]'s
  /// own [ReorderableDragStartListener]); mobile drags it on a long-press (the
  /// [material.ReorderableDelayedDragStartListener] wrapper below). Null when
  /// the role list isn't reorderable (it always is, but keep it optional).
  final int? reorderableIndex;

  /// Whether the role's focuses are currently disclosed below this header.
  final bool expanded;

  /// The role's child focuses, used to compute the collapsed reverse-inherited
  /// status (bold / unread dot). The header itself does not render them.
  final List<Priority> childFocuses;

  /// Run when a **collapsed** header row (not the "…" menu) is tapped. In the
  /// left panel this selects the role's first focus (which expands it); in
  /// single-panel mode it only discloses the role's focuses, never navigating.
  /// Ignored once the role is [expanded] — the expanded header is inert.
  final VoidCallback onTap;

  /// When true, render muted at rest and reintroduce the role colour on hover
  /// or when expanded — matching the left-panel focus tiles.
  final bool monochrome;

  /// Border radius for the hover/selection highlight (rounded pill in the
  /// left panel, rectangular edge-to-edge single-panel).
  final BorderRadius? borderRadius;

  /// Roomier single-panel mobile treatment: a larger (body-size) eyebrow, its
  /// left edge aligned to the roomy focus rows' leading gutter, and a taller
  /// hover pill matching those 36px rows. Off (the compact eyebrow) elsewhere.
  /// Set by [PrioritiesList] only.
  final bool roomy;

  @override
  State<RoleHeader> createState() => _RoleHeaderState();
}

class _RoleHeaderState extends State<RoleHeader> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    // A collapsed role still reverse-inherits its children's *colour* status
    // (full colour when any focus is active) and an unread dot when any focus is
    // unread. Expanded roles show no dot (the focuses below carry their own
    // cues). Weight, however, is no longer a status signal — the role name
    // always renders at the heavier weight (see below).
    final anyActive = widget.childFocuses.any((f) => f.active);
    final anyUnread = widget.childFocuses.any((f) => f.unread);
    final bool showDot = !widget.expanded && anyUnread;

    // Hover / expansion promotes the role to its full colour; otherwise it
    // reads as a muted version of its own colour (or muted resting tone when
    // monochrome and idle), just like the focus tiles. A collapsed role with
    // active focuses also shows in full colour.
    final isActive = _isHovered || widget.expanded;
    final accent = context.colour.colours.fromTheme(role.displayColor);
    final restingColor = context.colour.colours.fromTheme(
      role.displayColor,
      muted: true,
    );
    final labelColor = widget.monochrome && !isActive && !anyActive
        ? restingColor
        : accent;

    // The hover/selection pill background, in the role's own colour — exactly
    // the tint focus tiles use (null outside the monochrome left panel, where
    // the neutral [plotColors.highlight] fallback applies instead). Only a
    // *collapsed* role paints it; the expanded role stays flat (see below).
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(role.displayColor)
        : null;

    // The role row renders at a focus tile's full height ([tileHeight]) so its
    // (collapsed) hover pill matches the focuses' — but its layout *footprint*
    // is compressed to the shorter [layoutHeight], so the eyebrow keeps its
    // tight spacing. [compress] absorbs the difference into the gap around the
    // role: the tile overflows that gap symmetrically instead of pushing its
    // neighbours. The eyebrow (centred in the tile) stays put, and the row
    // height is identical collapsed vs expanded, so the disclosure never jumps.
    final tileHeight = widget.roomy
        ? listRowGutter + context.theme.spacing.sm * 2
        : context.theme.iconSizes.base * 2;
    final layoutHeight =
        context.theme.iconSizes.base +
        (widget.roomy ? context.theme.spacing.lg : context.theme.spacing.md);
    // Let the tile lay out at its own natural (focus-tile) height — capping it
    // would clip the body once the 1px border is accounted for — and centre it
    // in the shorter [layoutHeight] footprint, overflowing the gap evenly.
    Widget compress(Widget child) => SizedBox(
      height: layoutHeight,
      child: OverflowBox(
        minHeight: 0,
        maxHeight: double.infinity,
        alignment: Alignment.center,
        child: child,
      ),
    );

    final listTile = ListTile(
      // A collapsed role is a tap target (selects its first focus, expanding
      // it). The expanded role is the current section header — tapping it does
      // nothing.
      onTap: widget.expanded ? null : widget.onTap,
      // Menu opens via long-left swipe on touch (see wrapper below); long-
      // press is reserved for the reorder drag on the row.
      longPressCommand: null,
      // The header IS the role drag handle. On desktop, ListTile wires its own
      // ReorderableDragStartListener off this index (pointer-down on the
      // header starts the role drag) — and because the accordion runs the role
      // list in handle-only mode, the expanded role's inner focus list is NOT
      // blanketed by an outer drag target, so dragging a focus row stays a
      // focus drag. (Mobile uses the delayed wrapper below.)
      reorderableIndex: widget.reorderableIndex,
      borderRadius: widget.borderRadius,
      // Collapsed roles get the same hover pill as the focus tiles (in the
      // role's own colour). The expanded role is a flat section header — it's
      // not a tap target, so it never highlights.
      noHoverHighlight: widget.expanded,
      highlightColor: accentBg,
      onHover: (hovered) {
        if (mounted && _isHovered != hovered) {
          setState(() => _isHovered = hovered);
        }
      },
      // No leading icon — the role reads as a flush-left section label. A bare
      // left spacer (the shared sidebar left inset) pulls the role name to the
      // same left edge as the FYI / Everything tiles and the focus icons below
      // it, so the whole sidebar shares one left margin.
      leadingBuilder: (isHovered, hasFocus) => SizedBox(
        // Align the eyebrow's left edge with the focus rows' leading gutter
        // below it: sm in roomy mode (the compose picker's header indent), lg
        // in the compact sidebar.
        width: widget.roomy
            ? context.theme.spacing.sm
            : context.theme.spacing.lg,
      ),
      // Role name as an uppercase eyebrow + (collapsed) unread dot. The dot
      // sits outside the Flexible so it survives title truncation. The name is
      // uppercased render-only (the stored [Role.name] keeps its original
      // case). The role name always renders at the heavier weight (w600) so a
      // role stays a prominent section heading regardless of whether it's
      // expanded/collapsed or has active focuses; colour (identity / active
      // status) and the unread dot carry the remaining signals.
      body: Row(
        children: [
          Flexible(
            child: Text(
              role.name.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: eyebrowLabelStyle(context.theme.typography).copyWith(
                color: labelColor,
                fontWeight: FontWeight.w600,
                // Roomy role headers step up to the body size (md) — larger than
                // the compose picker's section headers, since a role is a
                // tappable section in its own right — while keeping the
                // uppercase + tracking + colour eyebrow treatment. Compact keeps
                // the small xs eyebrow.
                fontSize: widget.roomy
                    ? context.theme.typography.md.fontSize
                    : null,
              ),
            ),
          ),
          if (showDot)
            Padding(
              padding: EdgeInsets.only(left: context.theme.spacing.sm),
              child: PriorityNotification(
                unread: true,
                color: role.displayColor,
              ),
            ),
        ],
      ),
      // Reserve the full menu-button slot height so the role row is the same
      // height as a focus tile (its hover pill therefore matches theirs). The
      // tighter *visual* spacing is restored by compressing the row's layout
      // footprint below (see `compress`) — the tile overflows into the
      // surrounding gap rather than being physically shorter. At rest a
      // *collapsed* role shows a faint role-hue chevron — a quiet "openable"
      // cue — overlaid centred on the "…" menu ([ShowRoleCommands]) footprint,
      // so the chevron and the "…" sit in the same spot. The expanded role is
      // inert: just the reserved (invisible) slot, menu revealed on hover.
      trailingBuilder: (isHovered, hasFocus) {
        final hovered = isHovered || hasFocus;
        return Padding(
          padding: EdgeInsets.only(right: context.theme.spacing.sm),
          child: SizedBox(
            height: tileHeight,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Visibility(
                    visible: hovered,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: Button.icon(ShowRoleCommands(role)),
                  ),
                  if (!hovered && !widget.expanded)
                    Icon(
                      PlotIcon.right,
                      size: context.theme.iconSizes.xs,
                      color: context.colour.colours.fromTheme(
                        role.displayColor,
                        lightness: 0.66,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (hasPhysicalKeyboard()) return compress(listTile);

    // Touch: open the role menu via a long-left swipe, and start the role
    // reorder drag on a long-press of the header only. Wrapping just the header
    // (not the whole role section) keeps the role drag from competing with the
    // expanded role's inner focus list, whose rows have their own long-press
    // drag. A horizontal swipe still wins the gesture arena for the menu (see
    // Swipeable's hit-slop recognizer), so the two don't fight.
    final swipeable = Swipeable(
      key: ValueKey('role-${role.id}'),
      endLongCommand: ShowRoleCommands(role),
      child: listTile,
    );
    final index = widget.reorderableIndex;
    if (index == null) return compress(swipeable);
    return compress(
      material.ReorderableDelayedDragStartListener(
        index: index,
        child: swipeable,
      ),
    );
  }
}
