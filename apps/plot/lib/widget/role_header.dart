import 'package:flutter/material.dart' as material;

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/widget.dart';

/// A collapsible role header row in the accordion sidebar. Renders the role's
/// name (in its colour, muted at rest like a focus tile) as a flush-left
/// section label — no leading caret — and a hover-revealed "…" menu
/// ([ShowRoleCommands]). Tapping a **collapsed** header runs [onTap] (the left
/// panel selects the role's first focus; single-panel just discloses them); the
/// **expanded** header is inert. When the role is **collapsed**, its status is
/// reverse-inherited from its child focuses:
///
/// - **bold** when any child focus is active, and
/// - an unread **dot** ([PriorityNotification]) when any child focus is unread.
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
    this.textStyle,
    this.reorderableIndex,
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

  /// Base text style for the role name (the sidebar item style).
  final TextStyle? textStyle;

  @override
  State<RoleHeader> createState() => _RoleHeaderState();
}

class _RoleHeaderState extends State<RoleHeader> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    // Collapsed roles reverse-inherit their children's status: bold when any
    // focus is active, an unread dot when any focus is unread. Expanded roles
    // show neither (the focuses below carry their own cues).
    final anyActive = widget.childFocuses.any((f) => f.active);
    final anyUnread = widget.childFocuses.any((f) => f.unread);
    final bool bold = !widget.expanded && anyActive;
    final bool showDot = !widget.expanded && anyUnread;

    // Hover / expansion promotes the role to its full colour; otherwise it
    // reads as a muted version of its own colour (or muted resting tone when
    // monochrome and not bold), just like the focus tiles.
    final isActive = _isHovered || widget.expanded;
    final accent = context.colour.colours.fromTheme(role.displayColor);
    final restingColor = context.colour.colours.fromTheme(
      role.displayColor,
      muted: true,
    );
    final labelColor = widget.monochrome && !isActive && !bold
        ? restingColor
        : accent;

    // The hover/selection pill background, in the role's own colour — exactly
    // the tint focus tiles use (null outside the monochrome left panel, where
    // the neutral [plotColors.highlight] fallback applies instead). Only a
    // *collapsed* role paints it; the expanded role stays flat (see below).
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(role.displayColor)
        : null;

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
      leadingBuilder: (isHovered, hasFocus) =>
          SizedBox(width: context.theme.spacing.lg),
      // Role name + (collapsed) unread dot. The dot sits outside the Flexible
      // so it survives title truncation.
      body: Row(
        children: [
          Flexible(
            child: Text(
              role.name,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: (widget.textStyle ?? const TextStyle()).copyWith(
                color: labelColor,
                fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
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
      // Reserve the menu-button slot height so the header row matches the
      // focus tiles, then reveal the "…" menu on hover/focus. Mirrors
      // PriorityWidget's buttonSlotHeight.
      trailingBuilder: (isHovered, hasFocus) {
        final buttonSlotHeight = context.theme.iconSizes.base * 2;
        final hovered = isHovered || hasFocus;
        return Padding(
          padding: EdgeInsets.only(right: context.theme.spacing.sm),
          child: SizedBox(
            height: buttonSlotHeight,
            child: Center(
              child: hovered
                  ? Button.icon(ShowRoleCommands(role))
                  : Visibility(
                      visible: false,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Button.icon(ShowRoleCommands(role)),
                    ),
            ),
          ),
        );
      },
    );

    if (hasPhysicalKeyboard()) return listTile;

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
    if (index == null) return swipeable;
    return material.ReorderableDelayedDragStartListener(
      index: index,
      child: swipeable,
    );
  }
}
