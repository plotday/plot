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

/// The most recently created role in [roles], or null when empty. Used to pick
/// the role the single-panel accordion defaults open (see
/// [expandedRoleWithFallback]).
Role? mostRecentRole(List<Role> roles) {
  if (roles.isEmpty) return null;
  var newest = roles.first;
  for (final role in roles.skip(1)) {
    if (role.createdAt.isAfter(newest.createdAt)) newest = role;
  }
  return newest;
}

/// The role the focus accordion should keep disclosed.
///
/// In single-panel mode the focus sidebar IS the whole screen, so a fully
/// collapsed accordion (every role shut) leaves the user no way to reach any
/// focus. To prevent that, when no role is selection- or tap-driven open
/// ([preferred] is null) we re-open the role of the **last focus the user
/// opened** ([lastSelected]) — so returning to the list after visiting another
/// tab lands them back in the role they were working in. Before any focus has
/// been opened this session (or when that role was since removed), we fall back
/// to the **most recently created** role so exactly one is always open.
///
/// With <= 1 role there's no accordion (the list renders flat) and in
/// multi-panel mode the feed sits beside the sidebar, so neither needs the
/// fallback — both return [preferred] unchanged.
RoleId? expandedRoleWithFallback({
  required bool singlePanel,
  required List<Role> roles,
  required RoleId? preferred,
  RoleId? lastSelected,
}) {
  if (preferred != null) return preferred;
  if (!singlePanel || roles.length <= 1) return null;
  // Re-open the last role the user worked in, but only while it still exists;
  // a removed role falls through to the most-recent default below.
  if (lastSelected != null && roles.any((r) => r.id == lastSelected)) {
    return lastSelected;
  }
  return mostRecentRole(roles)?.id;
}

/// The focus sidebar. Focuses are grouped under their [Role]; the layout
/// depends on how many roles the user has:
///
/// - **0–1 roles:** a flat, drag-reorderable list of focuses, exactly as before
///   roles existed — no role header.
/// - **2+ roles:** an accordion. An outer drag-reorderable list of collapsible
///   [RoleHeader]s; the role whose focus is currently selected
///   ([expandedRoleId]) discloses an inner drag-reorderable list of its
///   focuses (animated open/closed). It's a pure accordion — exactly one role
///   is expanded (the selected focus's role), derived client-side, never
///   persisted. In single-panel mode, where this sidebar is the whole screen,
///   a fully collapsed accordion would strand the user, so when no focus is
///   current (e.g. after returning to the list from another tab) the role of
///   the last focus the user opened stays open — falling back to the most
///   recently created role before anything's been opened (see
///   [expandedRoleWithFallback]).
///
/// Each role's Inbox and FYI are ordinary focuses (drag-reorderable, they bold
/// when active and show unread), just with a fixed name + icon — and the FYI is
/// muted. They default to the bottom two of the role (Inbox then FYI) via large
/// server-seeded sentinel orders, so a freshly added focus lands above them.
///
/// Below the (flat or accordion) list come the "Add a focus" tail and finally
/// the "Everything" feed — both scroll with the list. There is no longer a
/// fixed global Inbox tile; each role owns its own Inbox focus.
///
/// Reordering writes the existing `order` column via [Order.between]: roles in
/// the outer list, focuses within their role's inner list. Cross-role focus
/// drag is out of scope.
class PrioritiesList extends StatefulWidget {
  final List<Priority> focuses;
  final Priority root;
  final Priority? selected;

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
    // Every focus renders inline in this list — each role's Inbox (including
    // the Personal role's) and the per-role FYI focus are all ordinary
    // reorderable focuses here. The old global Inbox tile is gone, and with
    // the vestigial `root` flag dropped there is no longer a non-inbox root to
    // exclude (the synthetic "Everything" tile, appended below, covers it).
    // The FYI is an ordinary focus and gets a newspaper glyph (see
    // [PriorityListTile]), so it is not filtered out.
  }) : focuses = (priorities.toList()..sort(_byOrder));

  /// Sidebar focus ordering: purely by [Order], then creation time. The Inbox
  /// and FYI are ordinary reorderable focuses; they default to the bottom two
  /// of their role via large server-seeded sentinel orders, not a comparator
  /// pin. Shared by the flat list and each role's inner list.
  static int _byOrder(Priority a, Priority b) {
    final c = a.order.value.compareTo(b.order.value);
    return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
  }

  @override
  State<PrioritiesList> createState() => _PrioritiesListState();
}

class _PrioritiesListState extends State<PrioritiesList> {
  /// Single-panel only: the role the user has manually disclosed by tapping its
  /// header, when that differs from the selection-derived [widget.expandedRoleId].
  ///
  /// In single-panel mode the focus sidebar IS the screen, so navigating into a
  /// focus replaces it — there'd be no chance to choose a different focus. So a
  /// role tap there must *only* disclose the role's focuses, never select one or
  /// navigate. That disclosure has no backing in the selection-derived
  /// [widget.expandedRoleId] (which only moves when a focus is actually
  /// selected), so we hold it here. Cleared the moment a real navigation lands
  /// (see [didUpdateWidget]) so the freshly-selected focus's role takes over.
  /// Always null in the left panel, where a role tap selects the first focus.
  RoleId? _manualExpandedRoleId;

  /// Single-panel only: the role of the last focus the user opened. It outlives
  /// the selection-derived [widget.expandedRoleId] (which drops to null when no
  /// focus is current — e.g. after returning to the focus list from another
  /// bottom-nav tab), so the accordion can re-disclose the role the user was
  /// last working in instead of collapsing every role. Until the first focus is
  /// opened this session it stays null and the fallback uses the most recent
  /// role (see [expandedRoleWithFallback]). Kept across tab switches because
  /// [PrioritiesList]'s State is on the always-alive home tab.
  RoleId? _lastSelectedRoleId;

  @override
  void initState() {
    super.initState();
    // Seed from the initial selection so a focus that is already current when
    // the list first builds is the one re-opened after the selection clears.
    _lastSelectedRoleId = widget.expandedRoleId;
  }

  @override
  void didUpdateWidget(PrioritiesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A real navigation recomputes the selection-derived [expandedRoleId]
    // upstream. When that changes, drop any manual single-panel override so the
    // newly-selected focus's role drives the disclosure instead of a stale tap.
    if (widget.expandedRoleId != oldWidget.expandedRoleId) {
      _manualExpandedRoleId = null;
    }
    // Remember the role of the focus the user is in. Captured here (rather than
    // only on tap) so opens from anywhere — the agenda, search, a thread link —
    // are remembered too: the list rebuilds on every selection change even
    // while it sits offstage behind another tab.
    if (widget.expandedRoleId != null) {
      _lastSelectedRoleId = widget.expandedRoleId;
    }
  }

  /// Non-archived focuses filed under [roleId], sorted by [PrioritiesList._byOrder]
  /// (Inbox last). Mirrors [PrioritiesState.focusesForRole], but scoped to the
  /// [PrioritiesList.focuses] this widget was handed (already non-root, sorted).
  List<Priority> _focusesForRole(RoleId roleId) {
    return widget.focuses.where((p) => p.roleId == roleId).toList();
  }

  /// Whether to draw the per-role "whisper rail" — the 1px hued left border that
  /// indents an open role's focuses. Flip to `false` to preview the focuses
  /// flush under their eyebrow with no rail, so the hierarchy rests on the
  /// uppercase eyebrow + the group gaps alone. A getter (not a `const`) so
  /// neither branch of [_focusGroup] reads as dead code while we A/B it.
  bool get _showFocusRail => false;

  /// Lays out an open role's disclosed focus [list] under its eyebrow. Always
  /// adds a tight [PlotSpacing.xs] gap below the role header. When
  /// [_showFocusRail] is set it also wraps the list in the whisper rail: a 1px
  /// left border in a pale tint of the role's hue ([borderFromTheme]) inset
  /// [PlotSpacing.lg] from the panel edge, with a small [PlotSpacing.sm] inner
  /// pad. (Focus rows keep their own `sidebarLeading` 14px inset, which already
  /// supplies most of the rail→icon gap — a larger pad just double-counts it and
  /// pushes the focuses too far right.) Lives inside the disclosure's
  /// `SizeTransition`, so a collapsed role shows nothing.
  Widget _focusGroup(BuildContext context, Role role, Widget list) {
    final topGap = context.theme.spacing.xs;
    if (!_showFocusRail) {
      return Padding(padding: EdgeInsets.only(top: topGap), child: list);
    }
    return Container(
      margin: EdgeInsets.only(top: topGap, left: context.theme.spacing.lg),
      padding: EdgeInsets.only(left: context.theme.spacing.sm),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: context.colour.colours.borderFromTheme(role.displayColor),
            width: 1,
          ),
        ),
      ),
      child: list,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        final isLeftPanel =
            PanelPositionProvider.of(context) == HeaderPosition.left;
        // Single panel: a role tap only discloses its focuses (no navigation),
        // tracked locally in [_manualExpandedRoleId]. Left panel: a role tap
        // selects its first focus, so expansion stays purely selection-derived.
        final singlePanel = !layoutState.multiPanel;
        // The role the selection (or a single-panel header tap) discloses. Null
        // when the Everything feed is active and nothing has been tapped.
        final RoleId? preferredExpandedRoleId = singlePanel
            ? (_manualExpandedRoleId ?? widget.expandedRoleId)
            : widget.expandedRoleId;
        // Single-panel must always keep one role open — a fully collapsed
        // sidebar (the whole screen here) gives no way to reach a focus. With
        // nothing else open, re-open the role of the last focus the user worked
        // in, falling back to the most recent role before anything's been opened.
        final RoleId? effectiveExpandedRoleId = expandedRoleWithFallback(
          singlePanel: singlePanel,
          roles: widget.roles,
          preferred: preferredExpandedRoleId,
          lastSelected: _lastSelectedRoleId,
        );
        // Default weight for the focus / Add-a-focus / Everything tiles —
        // regular; focus tiles go bold when they have active threads. (Role
        // headers don't use this style: they always render at the heavier
        // weight via [RoleHeader].)
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

        // Vertical gap above each role group (between groups). Touch devices get
        // a touch more air so the groups stay easy to separate by eye and tap;
        // desktop (mouse) reads cleanly tighter. Both are well below the old
        // [PlotSpacing.xl] (20), which left the sidebar feeling loose.
        final double roleGroupGap = isMobilePlatform()
            ? context.theme.spacing.lg // 14
            : context.theme.spacing.md; // 10

        TextStyle focusStyle(Priority p) => itemStyle.copyWith(
          color: p.archivedAt != null
              ? context.theme.colors.mutedForeground
              // A role's Inbox follows its role's colour (its own stored
              // `color` may be NULL); [Priority.labelDisplayColor] resolves it.
              : context.colour.colours.fromTheme(
                  p.labelDisplayColor,
                  muted: !monochrome && !p.unread,
                ),
        );

        // The roles that drive the accordion. <= 1 role keeps the flat layout.
        final accordion = widget.roles.length > 1;

        // Builds the drag-reorderable list of a single role's focuses (also
        // reused for the whole flat list). Each row keys on its id so it
        // survives unread/active churn without remounting. Focuses are never
        // indented — under their role header they stay flush-left with the FYI
        // and Everything tiles, all sharing one left edge.
        Widget focusList(List<Priority> list) {
          return ReorderableListView<Priority>(
            list: list,
            shrinkWrap: true,
            keyExtractor: (p) => ValueKey(p.id),
            itemBuilder: (context, priority, reorderableIndex) => PriorityWidget(
              key: ValueKey('focus-${priority.id}'),
              priority: priority,
              monochrome: monochrome,
              selected: !widget.everything && widget.selected?.id == priority.id,
              selectedBorder: true,
              borderRadius: itemBorderRadius,
              textStyle: focusStyle(priority),
              unread: priority.unread ? true : null,
              reorderableIndex: reorderableIndex,
            ),
            onReorder: (oldIndex, newIndex) =>
                _onReorderFocus(list, oldIndex, newIndex),
          );
        }

        // "Add a focus" closes off the list — it scrolls with the focuses, not
        // pinned below. In the accordion it defaults new focuses to the
        // currently disclosed role (the manual single-panel one, if any).
        final addFocusTile = ListTile(
          command: CommandWrapper(
            AddFocus(defaultRoleId: effectiveExpandedRoleId),
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
          isSelected: widget.everything,
          command: ChangeCurrentPriority.everything(),
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
            list: widget.roles,
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
              final expanded = role.id == effectiveExpandedRoleId;
              return _RoleSection(
                key: ValueKey('role-${role.id}'),
                expanded: expanded,
                // A clear gap separates each role group from the one above —
                // except the topmost, which already sits below the list's own
                // top padding. Keyed on position so it stays correct after a
                // role reorder.
                topGap: (reorderableIndex ?? 0) > 0 ? roleGroupGap : 0.0,
                header: RoleHeader(
                  role: role,
                  expanded: expanded,
                  childFocuses: childFocuses,
                  monochrome: monochrome,
                  borderRadius: itemBorderRadius,
                  reorderableIndex: reorderableIndex,
                  onTap: () {
                    if (singlePanel) {
                      // Single panel: the sidebar is the whole screen, so a role
                      // tap must ONLY disclose the role's focuses — never select
                      // one or navigate (that would jump straight into the first
                      // focus, leaving no way to pick another). RoleHeader passes
                      // null onTap once expanded, so this only fires for a
                      // collapsed role: always an expand.
                      setState(() => _manualExpandedRoleId = role.id);
                      return;
                    }
                    // Left panel: selecting the role's first focus expands it and
                    // shows its feed alongside the still-visible sidebar. Roles
                    // always have at least their Inbox, so the list is non-empty
                    // in practice; guard anyway.
                    if (childFocuses.isNotEmpty) {
                      context.run(ChangeCurrentPriority(childFocuses.first));
                    }
                  },
                ),
                // The disclosed focus list, laid out under the eyebrow (with
                // the whisper rail when [_showFocusRail] is on). Built for every
                // role and kept mounted (clipped to zero height when collapsed)
                // — see [_RoleSection.build] for why this avoids the nested-
                // reorderable layout crash.
                childBuilder: () =>
                    _focusGroup(context, role, focusList(childFocuses)),
              );
            },
            onReorder: (oldIndex, newIndex) =>
                _onReorderRole(widget.roles, oldIndex, newIndex),
          );
        } else {
          // 0–1 roles: a flat list over every focus (Inbox last) — exactly the
          // pre-roles layout, with no role header. Rendering all [focuses]
          // (rather than only the lone role's) guarantees no focus is ever
          // hidden if its roleId hasn't backfilled yet.
          listBody = focusList(widget.focuses);
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
                if (!accordion && widget.focuses.isEmpty)
                  Text(
                    'Add a focus to gather work related to a role, project, or activity.',
                    style: TextStyle(
                      color: context.theme.plotColors.veryMuted,
                      fontSize: context.theme.typography.sm.fontSize,
                    ),
                  ),
                addFocusTile,
                // Each role's FYI focus is an ordinary focus row inside the
                // (flat or accordion) list above — no separate fixed tile.
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
    this.topGap = 0.0,
    super.key,
  });

  final Widget header;

  /// Height of the gap above this role group (0 for the topmost — it already
  /// clears the list's own top padding). Sets the between-groups rhythm; the
  /// parent picks the value (platform-aware). See `roleGroupGap`.
  final double topGap;

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
        if (widget.topGap > 0) SizedBox(height: widget.topGap),
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
        // Cap-height leading size so this fixed tile's glyph matches the focus
        // and connection tiles in the same sidebar column.
        final iconSize = context.theme.iconSizes.leading;
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
