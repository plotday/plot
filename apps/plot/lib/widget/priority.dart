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
import 'package:plot/util/theme_color.dart';

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
    // The selected focus gets a crisp ring in its own colour (see the
    // agent/activity feed). Only in the left-panel monochrome frame — single-
    // panel mode keeps the plain edge-to-edge treatment.
    final priorityRing = widget.monochrome
        ? buildContext.colour.colours.borderFromTheme(priority.displayColor)
        : null;
    final priorityAccent = buildContext.colour.colours.fromTheme(
      priority.displayColor,
    );
    // At rest a focus shows a muted version of its own colour (not a flat
    // monochrome tone), so the colour is always legible and edits to it are
    // visible without hovering. Hover / selection promotes it to the full
    // accent. The title's fontWeight (w500) keeps it prominent.
    final restingColor = buildContext.colour.colours.fromTheme(
      priority.displayColor,
      muted: true,
    );

    // In monochrome mode, the resting text color is the muted focus colour and
    // the priority's own (full) color only shows on hover or when selected. The
    // hover background matches the selected background so the two states
    // look identical.
    final effectiveTextStyle = widget.monochrome && !isActive
        ? widget.textStyle?.copyWith(color: restingColor)
        : widget.textStyle;
    // A focus is "bold" when it has active threads (or for search's
    // ancestry-leaf emphasis). Bold tiles are never muted — their colour
    // shows at rest, just like on hover/selection.
    final bool bold = priority.active || widget.boldLeaf;
    // The leading focus icon and the title share one colour so they always
    // match: a muted tone at rest on the left-panel frame, the focus colour
    // when bold, hovered, or selected.
    final labelColor = widget.monochrome && !isActive && !bold
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
                else
                  // Focuses are flat — no "pin to top" affordance.
                  Button.icon(ShowPriorityCommands(priority)),
              ],
            ),
          ),
        );
      },
      title: null,
      body: _buildLabel(buildContext, isActive, restingColor, labelColor, bold),
      selected: widget.selected,
      selectedBorder: widget.selectedBorder,
      selectedColor: priorityAccentBg,
      selectedBorderColor: priorityRing,
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
        final iconSize = buildContext.theme.iconSizes.base;
        // Leading focus icon, positioned with the standard command-tile
        // metrics: 20px from the panel edge, then a 12px gap to the title
        // (mirrors ListTile._buildContent's icon slot). The unread dot now
        // trails the title — see _buildLabel.
        return Padding(
          padding: const EdgeInsets.only(left: 20, right: 12),
          child: SizedBox.square(
            dimension: iconSize,
            child: Icon(
              PlotIcon.focusIcon(priority.icon),
              size: iconSize,
              color: labelColor,
            ),
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
    Color labelColor,
    bool bold,
  ) {
    final priority = widget.priority;
    // Focuses are flat — the list row renders its own leading icon, so the
    // label is just the (already-flattened) title in the focus colour, kept
    // the same colour as the leading icon. Bold (active) when [bold].
    final Widget label = FocusLabel(
      priority: priority,
      fontSize: widget.textStyle?.fontSize,
      height: 1,
      color: labelColor,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      showIcon: false,
    );

    // The unread dot trails the title now that the focus icon owns the
    // leading slot. It sits outside the Flexible title so it stays visible
    // even when the title ellipsizes.
    final bool isUnread = widget.unread ?? priority.unread;
    final Widget? notification = isUnread
        ? Padding(
            padding: EdgeInsets.only(left: buildContext.theme.spacing.sm),
            child: PriorityNotification(
              unread: true,
              color: priority.displayColor,
            ),
          )
        : null;

    final Widget? caret = widget.expandable
        ? _ExpandCaretButton(
            key: _caretKey,
            expanded: widget.expanded,
            color: widget.monochrome && !isActive
                ? restingColor
                : (widget.textStyle?.color ?? buildContext.colour.muted),
            onTap: widget.onToggleExpand,
          )
        : null;

    if (notification == null && caret == null) return label;

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        Flexible(child: label),
        ?notification,
        ?caret,
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
    this.fontWeight,
    this.onLeafTap,
    this.titleOverride,
    this.iconOverride,
    super.key,
  });

  final Priority? priority;
  final double? fontSize;
  final double? height;
  final bool muted;
  final Color? color;

  /// Renders this text instead of `priority.title`. Lets fixed semantic views
  /// (the Inbox / Everything feeds) reuse this label with their own wording.
  final String? titleOverride;

  /// Renders this glyph instead of the priority's chosen icon. Pair with
  /// [titleOverride] (and usually [color]) for the Inbox / Everything labels,
  /// which the sidebar draws with the inbox / inboxes glyphs in the brand
  /// colour rather than the root focus's own icon and colour.
  final IconData? iconOverride;

  /// Whether to render the focus icon before the title. Off in contexts that
  /// already show the icon separately (e.g. a list row with its own leading).
  final bool showIcon;

  /// When true, render the title at semibold.
  final bool boldLeaf;

  /// Explicit title weight. Overrides [boldLeaf] when set; callers that want a
  /// uniform default weight (e.g. the sidebar list) pass this directly.
  final FontWeight? fontWeight;

  /// Tap handler for the title hit area.
  final VoidCallback? onLeafTap;

  @override
  Widget build(BuildContext context) {
    final p = priority;
    if (p == null) return const SizedBox.shrink();

    final resolvedFontSize = fontSize ?? context.theme.typography.md.fontSize;
    final accent =
        color ?? context.colour.colours.fromTheme(p.displayColor, muted: muted);

    final title = Text(
      titleOverride ?? p.title,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        color: accent,
        fontSize: resolvedFontSize,
        height: height,
        fontWeight: fontWeight ?? (boldLeaf ? FontWeight.w600 : null),
      ),
    );

    final children = <Widget>[
      if (showIcon) ...[
        Icon(
          iconOverride ?? PlotIcon.focusIcon(p.icon),
          size: resolvedFontSize,
          color: accent,
        ),
        const SizedBox(width: 6),
      ],
      Flexible(child: title),
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

/// Branded label for the Inbox (the root focus): the inbox glyph in the
/// Resolution brand colour with the fixed "Inbox" wording, matching how the
/// sidebar and header already draw it. Use this in every focus picker so the
/// Inbox row looks identical everywhere instead of falling back to the root
/// focus's own icon and colour.
Widget inboxLabel(BuildContext context, Priority root, {double? fontSize}) {
  return FocusLabel(
    priority: root,
    fontSize: fontSize,
    titleOverride: 'Inbox',
    iconOverride: PlotIcon.inbox,
    color: context.colour.colours.fromTheme(const ThemeColor.defaultColor()),
  );
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
