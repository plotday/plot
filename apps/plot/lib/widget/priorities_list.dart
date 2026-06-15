import 'package:collection/collection.dart';
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

/// The focus sidebar. Focuses are grouped under their [Role]; the layout
/// depends on how many roles the user has:
///
/// - **0–1 roles:** a flat, drag-reorderable list of focuses (the role's
///   Inbox last), exactly as before roles existed — no role header.
/// - **2+ roles:** an accordion. An outer drag-reorderable list of collapsible
///   [RoleHeader]s; the role whose focus is currently selected
///   ([expandedRoleId]) discloses an inner drag-reorderable list of its
///   focuses (animated open/closed). It's a pure accordion — exactly one role
///   is expanded (the selected focus's role), derived client-side, never
///   persisted.
///
/// Below the (flat or accordion) list come the "Add a focus" tail and finally
/// the "Everything" feed — both scroll with the list. There is no longer a
/// fixed global Inbox tile; each role owns its own Inbox focus.
///
/// Reordering writes the existing `order` column via [Order.between]: roles in
/// the outer list, focuses within their role's inner list. Cross-role focus
/// drag is out of scope.
class PrioritiesList extends StatelessWidget {
  final List<Priority> focuses;
  final Priority root;
  final Priority? selected;

  /// The single, role-less global "FYI" focus, if it exists. Rendered as a
  /// fixed row just above "Everything" (outside the role accordion), with a
  /// subtle unread dot but never bold. Excluded from [focuses] so it never
  /// appears in the flat/accordion list. Null when the user has no FYI focus.
  final Priority? fyi;

  /// The user's live roles, already sorted for the sidebar (see
  /// [PrioritiesState.sortedRoles]). With <= 1 role the list renders flat.
  final List<Role> roles;

  /// The role currently disclosed in the accordion — the selected focus's
  /// role, or null when the "Everything" feed is active. Passed in by the page
  /// (computed from `NowBloc`), never read from a Bloc here.
  final RoleId? expandedRoleId;

  /// True when the synthetic "Everything" feed is the active view. Both the
  /// per-role Inboxes and Everything are rooted on [root], so the Everything
  /// highlight is driven by this flag (from `NowBloc.everything`).
  final bool everything;

  PrioritiesList({
    super.key,
    required this.root,
    required List<Priority> priorities,
    this.roles = const [],
    this.selected,
    this.everything = false,
    this.expandedRoleId,
    // Keep the backfilled root focus when it is the Personal role's Inbox
    // (`root == true && isInbox == true`). The old global Inbox tile is gone,
    // so the Personal Inbox renders only through this list now; excluding all
    // roots would make it vanish for backfilled users. The non-inbox root (if
    // any survives pre-backfill) is still dropped — the Everything tile covers
    // it.
  }) : focuses =
           (priorities.where((p) => (!p.root || p.isInbox) && !p.isFyi).toList()
             ..sort(_byOrder)),
       fyi = priorities
           .where((p) => p.isFyi && p.archivedAt == null)
           .firstOrNull;

  /// Sidebar focus ordering: the (per-role) Inbox last, then by [Order], then
  /// creation time. Shared by the flat list and each role's inner list so both
  /// keep the Inbox at the bottom.
  static int _byOrder(Priority a, Priority b) {
    if (a.isInbox != b.isInbox) return a.isInbox ? 1 : -1; // Inbox last
    final c = a.order.value.compareTo(b.order.value);
    return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
  }

  /// Non-archived focuses filed under [roleId], sorted by [_byOrder] (Inbox
  /// last). Mirrors [PrioritiesState.focusesForRole], but scoped to the
  /// [focuses] this widget was handed (already non-root, already sorted).
  List<Priority> _focusesForRole(RoleId roleId) {
    return focuses.where((p) => p.roleId == roleId).toList();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final isLeftPanel =
            PanelPositionProvider.of(context) == HeaderPosition.left;
        // Every sidebar tile (focuses, role headers, Add a focus, Everything)
        // shares one default weight — regular. Focus tiles and (collapsed)
        // role headers go bold when they have active threads.
        final itemStyle =
            (isLeftPanel
                    ? context.theme.typography.sm
                    : context.theme.typography.md)
                .copyWith(fontWeight: FontWeight.w400);
        // In the left panel the list floats on the tinted frame with
        // horizontal insets — round the hover/selection highlights so they
        // read as discrete pills. Single-panel mode goes edge-to-edge, so
        // keep it rectangular.
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

        // The roles that drive the accordion. <= 1 role keeps the flat layout.
        final accordion = roles.length > 1;

        // Builds the drag-reorderable list of a single role's focuses (also
        // reused for the whole flat list). Each row keys on its id so it
        // survives unread/active churn without remounting.
        Widget focusList(List<Priority> list, {required bool indent}) {
          return ReorderableListView<Priority>(
            list: list,
            shrinkWrap: true,
            keyExtractor: (p) => ValueKey(p.id),
            itemBuilder: (context, priority, reorderableIndex) => PriorityWidget(
              key: ValueKey('focus-${priority.id}'),
              priority: priority,
              monochrome: monochrome,
              selected: !everything && selected?.id == priority.id,
              selectedBorder: true,
              borderRadius: itemBorderRadius,
              textStyle: focusStyle(priority),
              unread: priority.unread ? true : null,
              indentLevel: indent ? 1 : 0,
              reorderableIndex: reorderableIndex,
            ),
            onReorder: (oldIndex, newIndex) =>
                _onReorderFocus(list, oldIndex, newIndex),
          );
        }

        // "Add a focus" closes off the list — it scrolls with the focuses, not
        // pinned below. In the accordion it defaults new focuses to the
        // expanded role.
        final addFocusTile = ListTile(
          command: CommandWrapper(
            AddFocus(defaultRoleId: expandedRoleId),
            icon: Value(null),
            title: 'Add a focus',
          ),
          icon: PlotIcon.add,
          iconOnly: true,
          muted: true,
          highlightColor: monochrome ? const Color(0x00000000) : null,
          borderRadius: monochrome ? null : itemBorderRadius,
        );

        // The "Everything" feed — the unscoped view across every role and
        // focus. The last row in the scroll (after "Add a focus").
        final everythingTile = FixedFocusTile(
          title: 'Everything',
          icon: PlotIcon.inboxes,
          isSelected: everything,
          command: ChangeCurrentPriority(root, everything: true),
          menuCommand: null,
          // Everything never carries its own unread indicator and never bolds.
          hasUnread: false,
          active: false,
          borderRadius: itemBorderRadius,
          textStyle: itemStyle,
          monochrome: monochrome,
        );

        // The list body: an outer reorderable of role sections (accordion) or
        // a single flat focus list.
        final Widget listBody;
        if (accordion) {
          listBody = ReorderableListView<Role>(
            list: roles,
            shrinkWrap: true,
            keyExtractor: (r) => ValueKey(r.id),
            // Scope the role drag to the header. Without this, the outer list
            // would wrap the whole _RoleSection (header + the expanded role's
            // inner focus list) as one drag target, which on desktop steals
            // pointer-down from the inner focus rows. In handle-only mode the
            // header (RoleHeader) self-wraps the drag via its reorderableIndex,
            // and the inner focus ReorderableListView keeps its own gestures.
            handleOnly: true,
            itemBuilder: (context, role, reorderableIndex) {
              final childFocuses = _focusesForRole(role.id);
              final expanded = role.id == expandedRoleId;
              return _RoleSection(
                key: ValueKey('role-${role.id}'),
                expanded: expanded,
                header: RoleHeader(
                  role: role,
                  expanded: expanded,
                  childFocuses: childFocuses,
                  monochrome: monochrome,
                  borderRadius: itemBorderRadius,
                  textStyle: itemStyle,
                  reorderableIndex: reorderableIndex,
                  onTap: () {
                    // Tapping a header selects the role's first focus, which
                    // makes it the expanded role (and animates it open). Roles
                    // always have at least their Inbox, so the list is
                    // non-empty in practice; guard anyway.
                    if (childFocuses.isNotEmpty) {
                      context.run(ChangeCurrentPriority(childFocuses.first));
                    }
                  },
                ),
                // Lazily built so only the expanded (or currently-animating-
                // closed) role ever constructs its inner reorderable focus
                // list — collapsed roles pay nothing, and no nested reorderable
                // exists to compete for gestures. _RoleSection keeps the child
                // mounted through the close animation, then drops it.
                childBuilder: () => focusList(childFocuses, indent: true),
              );
            },
            onReorder: (oldIndex, newIndex) =>
                _onReorderRole(roles, oldIndex, newIndex),
          );
        } else {
          // 0–1 roles: a flat list over every focus (Inbox last) — exactly the
          // pre-roles layout, with no role header. Rendering all [focuses]
          // (rather than only the lone role's) guarantees no focus is ever
          // hidden if its roleId hasn't backfilled yet.
          listBody = focusList(focuses, indent: false);
        }

        final scrollable = ScrollEdgeFade(
          transparent: true,
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // md top padding sets the panel apart from the agenda above it.
                SizedBox(height: context.theme.spacing.md),
                listBody,
                if (!accordion && focuses.isEmpty)
                  Text(
                    'Add a focus to gather work related to a role, project, or activity.',
                    style: TextStyle(
                      color: context.theme.plotColors.veryMuted,
                      fontSize: context.theme.typography.sm.fontSize,
                    ),
                  ),
                addFocusTile,
                // The global, role-less FYI focus — a fixed row just above
                // "Everything", outside the accordion/reorderable list. Carries
                // a subtle unread dot but never bolds (active: false), and the
                // app badge / global unread indicator excludes it (Task 5.2).
                if (fyi != null)
                  FixedFocusTile(
                    title: 'FYI',
                    icon: PlotIcon.bullhorn,
                    isSelected: !everything && selected?.id == fyi!.id,
                    command: ChangeCurrentPriority(fyi!),
                    menuCommand: null,
                    hasUnread: fyi!.unread,
                    active: false,
                    borderRadius: itemBorderRadius,
                    textStyle: itemStyle,
                    monochrome: monochrome,
                  ),
                everythingTile,
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
            // natural height when there's room.
            Flexible(child: scrollable),
          ],
        );
      },
    );
  }

  /// Persist a focus reorder within its (flat or per-role) list.
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

  /// Persist a role reorder in the outer accordion list. Mirrors
  /// [_onReorderFocus] but writes [Role.order].
  Future<void> _onReorderRole(
    List<Role> peers,
    int oldIndex,
    int newIndex,
  ) async {
    final previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
    final nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

    final current = peers[oldIndex];
    Role? previous;
    if (previousIndex >= 0) previous = peers[previousIndex];
    Role? next;
    if (nextIndex < peers.length) next = peers[nextIndex];

    await current
        .copyWith(
          order: Value(Order.between(previous?.order, next?.order)),
          pending: const Value(2),
        )
        .save();
  }
}

/// One role's section in the accordion: a [RoleHeader] above an animated
/// disclosure of its focuses.
///
/// The disclosure slides (height) open/closed as [expanded] flips, driven by an
/// [AnimationController] feeding a [SizeTransition]. The inner focus list — a
/// nested [ReorderableListView] so focuses stay drag-reorderable within their
/// role — stays mounted whether the section is expanded or collapsed; only the
/// disclosure height animates. This mirrors the proven nested-priorities
/// `_AnimatedPriorityChildren` pattern and is what keeps the nested scrollable
/// crash-free; see [_RoleSectionState.build] for the full rationale.
class _RoleSection extends StatefulWidget {
  const _RoleSection({
    required this.header,
    required this.childBuilder,
    required this.expanded,
    super.key,
  });

  final Widget header;

  /// Builds the disclosed inner focus list (a nested [ReorderableListView] so
  /// focuses can be drag-reordered within their role). Built for every role —
  /// expanded or collapsed — and kept mounted; see [_RoleSectionState.build].
  final Widget Function() childBuilder;
  final bool expanded;

  @override
  State<_RoleSection> createState() => _RoleSectionState();
}

class _RoleSectionState extends State<_RoleSection>
    with SingleTickerProviderStateMixin {
  // Match the removal/disclosure feel used elsewhere (animated_removal.dart).
  static const _duration = Duration(milliseconds: 150);

  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: _duration,
      vsync: this,
      // Start fully open/closed to match the initial [expanded] — no opening
      // animation on first build (e.g. the role that owns the selected focus).
      value: widget.expanded ? 1 : 0,
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void didUpdateWidget(_RoleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    // The inner list stays mounted either way (see [build]); just drive the
    // disclosure height. No teardown-on-complete — keeping the nested
    // reorderable mounted is what avoids the layout crash.
    if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        // The inner focus list stays mounted whether the role is expanded or
        // collapsed; the controller only animates the disclosure height. This
        // mirrors the proven nested-priorities `_AnimatedPriorityChildren`
        // pattern (SizeTransition → ClipRect → child) and is what keeps the
        // nested focus `ReorderableListView` from crashing: SizeTransition lays
        // its child out at full natural size every frame and animates only the
        // clip + parent height, so the shrink-wrapping inner reorderable sees
        // stable constraints and never re-measures mid-animation. The earlier
        // lazy mount/unmount (`if (showChild)`) + `FadeTransition` variant
        // churned that nested scrollable's layout during the animation, leaving
        // a sliver with null `geometry` → the production layout-crash cascade
        // (PostHog 019ec304). Collapsed roles still build their inner list (laid
        // out, then clipped to zero height) — a small cost for a crash-free
        // disclosure that keeps focuses drag-reorderable.
        SizeTransition(
          sizeFactor: _curve,
          // Anchor the reveal to the top edge so the focus list grows down from
          // the header (not centred). `axisAlignment` is deprecated post v3.41;
          // `alignment: topCenter` is the replacement.
          alignment: Alignment.topCenter,
          child: ClipRect(child: widget.childBuilder()),
        ),
      ],
    );
  }
}

/// A fixed (non-reorderable) sidebar tile for the Everything view (and reused
/// by the global-search sidebar's "All matches" / "Inbox" tiles). Mirrors
/// [PriorityWidget]'s left-panel treatment — monochrome at rest, colour on
/// hover/selection — but without the reorder handle, weekly-total chip, or
/// expansion affordances. Renders in the fixed Resolution brand colour rather
/// than any focus's own colour.
class FixedFocusTile extends StatefulWidget {
  final String title;

  /// The leading icon (an inboxes glyph for Everything).
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
    // Fixed, semantic tiles render in the Resolution brand colour (index 7)
    // regardless of any focus's own colour.
    const tileColor = ThemeColor.defaultColor();
    final restingColor = context.colour.muted;
    // Muted at rest, like the focus tiles; the Resolution colour shows when
    // the tile is bold (active threads) or on hover/selection.
    final labelColor = widget.monochrome && !isActive && !widget.active
        ? restingColor
        : context.colour.colours.fromTheme(tileColor);
    final accentBg = widget.monochrome
        ? context.colour.colours.backgroundFromTheme(tileColor)
        : null;
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
        return sidebarLeading(
          context,
          Icon(widget.icon, size: iconSize, color: labelColor),
        );
      },
      // Title in the accent colour, with the unread dot trailing it (kept
      // outside the Flexible so it survives title truncation). Bold when the
      // tile has active threads.
      body: Row(
        children: [
          Flexible(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
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
      // Always reserve the menu-button slot height so the row height matches
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
