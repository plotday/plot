import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/time_tracking_modal.dart';
import 'package:plot/command/command.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';

class PriorityWidget extends StatefulWidget {
  const PriorityWidget({
    required this.priority,
    this.context,
    this.selected = false,
    this.selectedBorder = true,
    this.onHover,
    this.indentLevel = 0,
    this.textStyle,
    this.showAncestry = false,
    this.unread,
    this.reorderableIndex,
    this.onTap,
    this.borderRadius,
    this.monochrome = false,
    this.boldLeaf = false,
    this.expandable = false,
    this.expanded = false,
    this.onToggleExpand,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;

  /// Whether to show border when selected
  final bool selectedBorder;

  final void Function(bool hovered)? onHover;

  /// Indentation level for nested priorities
  final int indentLevel;

  /// Custom text style for the priority title
  final TextStyle? textStyle;

  /// Whether to show ancestry in the command (for top priorities)
  final bool showAncestry;

  /// Custom unread value (if null, uses priority.unread)
  final bool? unread;

  /// Index for reorderable list. If provided on mobile, shows trailing drag handle.
  final int? reorderableIndex;

  /// Optional tap callback that overrides the default navigation behavior.
  final VoidCallback? onTap;

  /// Border radius for the hover/selection highlight. When null, the
  /// highlight is rectangular and may show top/bottom selection borders.
  final BorderRadius? borderRadius;

  /// When true, render the tile in a monochrome resting state (foreground
  /// with reduced opacity) and reintroduce the priority color on hover or
  /// when selected — used for the left-panel priorities list which sits on
  /// the tinted frame outside the squircles.
  final bool monochrome;

  /// When true and the priority label is displayed with ancestry, render the
  /// leaf (this priority) in a heavier weight than its ancestor crumbs.
  final bool boldLeaf;

  /// When true, render an expand/collapse caret directly after the title.
  /// Tapping the caret runs [onToggleExpand] without changing the active
  /// priority.
  final bool expandable;

  /// Current expansion state. Drives the direction of the caret (down when
  /// expanded, right when collapsed).
  final bool expanded;

  /// Callback fired when the user taps the caret.
  final VoidCallback? onToggleExpand;

  @override
  State<PriorityWidget> createState() => _PriorityWidgetState();
}

class _PriorityWidgetState extends State<PriorityWidget> {
  bool _isHovered = false;
  // True when the in-flight pointer event started over the expand caret. Set
  // on PointerDown by the wrapping Listener (see `build` below) and read by
  // the gated `onTap` so taps on the caret expand/collapse without also
  // triggering navigation. The flag is overwritten on every PointerDown, so
  // it always reflects the most recent tap target.
  bool _caretSuppressedTap = false;
  final GlobalKey _caretKey = GlobalKey();

  bool _isOverCaret(Offset globalPosition) {
    final ctx = _caretKey.currentContext;
    if (ctx == null) return false;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    final origin = box.localToGlobal(Offset.zero);
    return (origin & box.size).contains(globalPosition);
  }

  @override
  Widget build(BuildContext buildContext) {
    final priority = widget.priority;
    bool isContext = priority == widget.context;
    // The notification box (PriorityNotification) is a 16×16 square that
    // centers a 6px dot — its own internal padding already gives the dot
    // visual breathing room. Sit the box close to the panel edge so labels
    // don't feel floating-right when no priorities are unread.
    final leadingH = buildContext.theme.spacing.sm;

    final isActive = widget.selected || _isHovered;
    final priorityAccentBg = widget.monochrome
        ? buildContext.colour.colours.backgroundFromTheme(priority.displayColor)
        : null;
    final priorityAccent = buildContext.colour.colours.fromTheme(
      priority.displayColor,
    );
    // Resting color matches the `muted: true` color used by ListTile for the
    // sibling connection / account tiles, so the whole left-panel frame reads
    // as a single tone at rest. The title's fontWeight (w500) keeps it more
    // prominent than the same-color subtitle.
    final restingColor = buildContext.colour.muted;

    // In monochrome mode, the resting text color is a single monochrome tone
    // and the priority's own color only shows on hover or when selected. The
    // hover background matches the selected background so the two states
    // look identical.
    final effectiveTextStyle = widget.monochrome && !isActive
        ? widget.textStyle?.copyWith(color: restingColor)
        : widget.textStyle;
    final indicatorColor = widget.monochrome && !isActive
        ? restingColor
        : priorityAccent;

    final navigationCommand = !isContext
        ? ChangeCurrentPriority(priority, ancestry: widget.showAncestry)
        : null;
    final listTile = ListTile(
      command: navigationCommand,
      onTap: () {
        if (_caretSuppressedTap) return;
        if (widget.onTap != null) {
          widget.onTap!();
        } else if (navigationCommand != null) {
          buildContext.run(navigationCommand);
        }
      },
      // Menu opens via long-left swipe on touch (see Swipeable wrapper
      // below) and via right-click on desktop (see ContextMenu wrapper
      // below). Long-press is reserved for starting a reorder drag.
      longPressCommand: null,
      trailingBuilder: (isHovered, hasFocus) {
        final hovered = isHovered || hasFocus;
        // Reserve vertical space so the tile height doesn't jump when hover
        // buttons appear. Width collapses to 0 when not hovered so the body
        // gets full width.
        final buttonSlotHeight = buildContext.theme.iconSizes.base * 2;

        return Padding(
          padding: EdgeInsets.only(right: leadingH),
          child: SizedBox(
            height: buttonSlotHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Resting: weekly total chip → tap opens the time-tracking
                // modal. Hover: swapped for icon controls; the Time log
                // action lives inside the More modal.
                if (!hovered)
                  _PriorityWeeklyTotal(
                    priority: priority,
                    selected: widget.selected,
                  )
                else ...[
                  Button.icon(
                    SetTopPriority(priority, priority.topOrder == null),
                  ),
                  Button.icon(ShowPriorityCommands(priority)),
                ],
              ],
            ),
          ),
        );
      },
      title: null,
      body: _buildLabel(buildContext, isActive, restingColor),
      selected: widget.selected,
      selectedBorder: widget.selectedBorder,
      selectedColor: priorityAccentBg,
      highlightColor: priorityAccentBg,
      highlighted: widget.selected,
      borderRadius: widget.borderRadius,
      onHover: (hovered) {
        widget.onHover?.call(hovered);
        if (mounted && _isHovered != hovered) {
          setState(() => _isHovered = hovered);
        }
      },
      indentLevel: widget.indentLevel,
      textStyle: effectiveTextStyle,
      leadingBuilder: (isHovered, hasFocus) {
        final isUnread = widget.unread ?? priority.unread;
        return Padding(
          padding: EdgeInsets.only(
            left: leadingH,
            right: buildContext.theme.spacing.sm,
            bottom: 2,
          ),
          child: PriorityNotification(
            unread: isUnread,
            color: priority.displayColor,
            // Keep the monochrome resting tone for the empty leading slot,
            // but let the unread dot render in the priority's own color so
            // it reads as a priority-tinted notification against the
            // monochrome frame.
            colorOverride: widget.monochrome && !isUnread
                ? indicatorColor
                : null,
          ),
        );
      },
    );

    // When the caret is rendered, intercept PointerDown to record whether the
    // tap started over the caret. Mobile uses a raw `Listener` for tap
    // detection that ignores the gesture arena, so without this the parent
    // ListTile would still navigate when the caret is tapped. Setting the
    // flag here works on both desktop and mobile.
    final Widget tile = widget.expandable
        ? Listener(
            behavior: HitTestBehavior.deferToChild,
            onPointerDown: (event) {
              _caretSuppressedTap = _isOverCaret(event.position);
            },
            child: listTile,
          )
        : listTile;

    if (hasPhysicalKeyboard()) {
      return ContextMenu(
        items: (close) => priorityCommands(priority)
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
                onPress: () {
                  close();
                  buildContext.run(cmd);
                },
              ),
            )
            .toList(),
        child: tile,
      );
    }

    // Touch: open the priority menu via a long-left swipe.
    return Swipeable(
      key: ValueKey(priority.id),
      endLongCommand: ShowPriorityCommands(priority),
      child: tile,
    );
  }

  Widget _buildLabel(
    BuildContext buildContext,
    bool isActive,
    Color restingColor,
  ) {
    final priority = widget.priority;
    // Focuses are flat — the list row renders its own leading icon, so the
    // label is just the (already-flattened) title in the focus colour.
    final Widget label = FocusLabel(
      priority: priority,
      fontSize: widget.textStyle?.fontSize,
      height: 1,
      color: widget.monochrome && !isActive ? restingColor : null,
      boldLeaf: widget.boldLeaf,
      showIcon: false,
    );

    if (!widget.expandable) return label;

    final caretColor = widget.monochrome && !isActive
        ? restingColor
        : (widget.textStyle?.color ?? buildContext.colour.muted);
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        Flexible(child: label),
        _ExpandCaretButton(
          key: _caretKey,
          expanded: widget.expanded,
          color: caretColor,
          onTap: widget.onToggleExpand,
        ),
      ],
    );
  }
}

class _ExpandCaretButton extends StatefulWidget {
  const _ExpandCaretButton({
    super.key,
    required this.expanded,
    required this.color,
    required this.onTap,
  });

  final bool expanded;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<_ExpandCaretButton> createState() => _ExpandCaretButtonState();
}

class _ExpandCaretButtonState extends State<_ExpandCaretButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final foreground = context.colour.foreground;
    final color = _hovered ? foreground : widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: Icon(
            widget.expanded
                ? FontAwesomeIcons.chevronDown
                : FontAwesomeIcons.chevronRight,
            size: 10,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// Standard widget for displaying a priority with its colored hierarchy.
///
/// Ancestor crumbs and the separator render in a muted variant of their
/// own colors so the leaf priority reads as the prominent label
/// ("bolded leaf" pattern from the agenda). Pass [color] to force a
/// single foreground for the whole label, or [mutedAncestorColor] to
/// override only the ancestor + separator color (e.g. on a tinted
/// background where the muted theme colors lose contrast).
///
/// Use this in all priority selection UIs:
/// - In SelectModal: `itemBuilder: (p) => ListTile(body: FocusLabel(priority: p))`
/// - In FormSelect: `labelBuilder: (p) => FocusLabel(priority: p)`
/// - For display: `FocusLabel(priority: priority, muted: true)` for subdued appearance
/// A flat label for a focus: its icon, in its colour, followed by its title.
///
/// Focuses are flat — there is no ancestry chain. (At apiVersion >= 4 the
/// server already projects the full label into `priority.title`, e.g. a
/// migrated "Work › Marketing".) Renamed from the former `PriorityLabel`.
class FocusLabel extends StatelessWidget {
  const FocusLabel({
    this.priority,
    this.fontSize,
    this.height,
    this.muted = false,
    this.color,
    this.showIcon = true,
    this.boldLeaf = false,
    this.leafTrailingIcon,
    this.onLeafTap,
    super.key,
  });

  final Priority? priority;
  final double? fontSize;
  final double? height;
  final bool muted;
  final Color? color;

  /// Whether to render the focus icon before the title. Off in contexts that
  /// already show the icon separately (e.g. a list row with its own leading).
  final bool showIcon;

  /// When true, render the title at semibold.
  final bool boldLeaf;

  /// Optional trailing icon (typically a caret) sharing a tap target with the
  /// title via [onLeafTap].
  final IconData? leafTrailingIcon;

  /// Tap handler for the combined title + [leafTrailingIcon] hit area.
  final VoidCallback? onLeafTap;

  @override
  Widget build(BuildContext context) {
    final p = priority;
    if (p == null) return const SizedBox.shrink();

    final resolvedFontSize = fontSize ?? context.theme.typography.md.fontSize;
    final accent =
        color ?? context.colour.colours.fromTheme(p.displayColor, muted: muted);

    final title = Text(
      p.title,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        color: accent,
        fontSize: resolvedFontSize,
        height: height,
        fontWeight: boldLeaf ? FontWeight.w600 : null,
      ),
    );

    final children = <Widget>[
      if (showIcon) ...[
        Icon(PlotIcon.focusIcon(p.icon), size: resolvedFontSize, color: accent),
        const SizedBox(width: 6),
      ],
      Flexible(child: title),
      if (leafTrailingIcon != null) ...[
        const SizedBox(width: 4),
        Icon(leafTrailingIcon, size: 10, color: accent),
      ],
    ];

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );

    if (onLeafTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onLeafTap,
      child: row,
    );
  }
}

/// Tracks pointer hover and rebuilds with the resolved colour.
class _HoverColored extends StatefulWidget {
  const _HoverColored({
    required this.restColor,
    required this.hoverColor,
    required this.builder,
  });

  final Color restColor;
  final Color hoverColor;
  final Widget Function(BuildContext context, Color color) builder;

  @override
  State<_HoverColored> createState() => _HoverColoredState();
}

class _HoverColoredState extends State<_HoverColored> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = _hovered ? widget.hoverColor : widget.restColor;
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: widget.builder(context, c),
    );
  }
}

/// Weekly time-tracking total displayed on the right of a [PriorityWidget]
/// tile. Always visible (unlike the hover-only action buttons that sit
/// next to it). Reads local Session rows for this week — no server call,
/// so the value is correct offline up to the latest sync.
///
/// Tapping opens [TimeTrackingModal] showing per-day totals with the
/// ±15m manual-adjustment controls.
class _PriorityWeeklyTotal extends StatefulWidget {
  const _PriorityWeeklyTotal({required this.priority, this.selected = false});

  final Priority priority;
  final bool selected;

  @override
  State<_PriorityWeeklyTotal> createState() => _PriorityWeeklyTotalState();
}

class _PriorityWeeklyTotalState extends State<_PriorityWeeklyTotal> {
  // Cache the combined stream so its identity stays stable across rebuilds.
  // Rebuilding it on every build() — which happens whenever an enclosing
  // bloc (NowBloc, PrioritiesBloc, …) emits — causes StreamBuilder to drop
  // its snapshot and re-subscribe, leaving the chip blank for a frame until
  // both inputs re-emit. That blank frame is the visible flicker.
  late Stream<Duration> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _buildStream();
  }

  @override
  void didUpdateWidget(_PriorityWeeklyTotal oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recreate only when the inputs that drive the query change. The
    // descendants stream keys off `priority.path.value`; the totals stream
    // keys off `priority` (via the ids set). Other priority fields (title,
    // color, unread, …) don't affect the duration so they shouldn't force
    // a resubscribe.
    if (oldWidget.priority.id != widget.priority.id ||
        oldWidget.priority.path != widget.priority.path) {
      _stream = _buildStream();
    }
  }

  Stream<Duration> _buildStream() {
    // Per-minute tick so the displayed total advances during an active
    // session even when no DB row updates — `Session.resume` only fires
    // when the priority has a pending target, so a plain DB stream
    // wouldn't tick for sessions tracked without one.
    return Rx.combineLatest3<Set<PriorityId>, List<Session>, void, Duration>(
      Session.watchSelfAndDescendantIds(widget.priority),
      Session.watch(range: Week.current()),
      Stream<void>.periodic(const Duration(minutes: 1), (_) {}).startWith(null),
      (ids, sessions, _) =>
          Session.sumDuration(sessions, ids, until: Time.now()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Aggregate over this priority AND its descendants by path — a parent's
    // row surfaces the rolled-up time spent anywhere in its subtree. Path
    // lookup is the source of truth (in-memory `children` aren't fully
    // hydrated on every priority instance — the priorities list only
    // links direct children, while the header has the full tree).
    return StreamBuilder<Duration>(
      stream: _stream,
      builder: (context, snapshot) {
        final total = snapshot.data ?? Duration.zero;
        // Hide the chip when there's nothing to show — never display 0m.
        if (total.inMinutes < 1) return const SizedBox.shrink();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              TimeTrackingModal(priority: widget.priority).show<void>(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              formatTrackedDuration(total),
              style: TextStyle(
                fontSize: context.theme.typography.xs.fontSize,
                fontWeight: FontWeight.w500,
                color: widget.selected
                    ? context.theme.colors.mutedForeground
                    : context.theme.plotColors.veryMuted,
                height: 1,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Compact "Xh Ym" formatter used by every time-tracking surface (tile
/// chip, header indicator, modal totals). Hours-only or minutes-only
/// elide the zero component. Caller is responsible for not showing the
/// result at all when the duration is zero (per the "never display 0m"
/// rule).
String formatTrackedDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes - h * 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}
