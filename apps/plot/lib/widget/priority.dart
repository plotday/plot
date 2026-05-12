import 'package:rxdart/rxdart.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/time_tracking_modal.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/layout.dart';
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
    this.active,
    this.reorderableIndex,
    this.onTap,
    this.borderRadius,
    this.monochrome = false,
    this.boldLeaf = false,
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

  /// Custom active value (if null, uses priority.active)
  final bool? active;

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

  @override
  State<PriorityWidget> createState() => _PriorityWidgetState();
}

class _PriorityWidgetState extends State<PriorityWidget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext buildContext) {
    final priority = widget.priority;
    bool isContext = priority == widget.context;
    final leadingH = buildContext.isMultiPanel
        ? buildContext.theme.spacing.lg
        : buildContext.theme.spacing.sm;

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

    final listTile = ListTile(
      command: !isContext
          ? ChangeCurrentPriority(priority, ancestry: widget.showAncestry)
          : null,
      onTap: widget.onTap,
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
                // modal. Hover: replaced by the Time log icon button so the
                // hover row stays a clean stack of icon controls.
                if (!hovered)
                  _PriorityWeeklyTotal(
                    priority: priority,
                    selected: widget.selected,
                  )
                else ...[
                  Button.icon(ShowTimeLog(priority)),
                  Button.icon(
                    SetTopPriority(
                      priority,
                      priority.topOrder == null,
                    ),
                  ),
                  Button.icon(ShowPriorityCommands(priority)),
                ],
              ],
            ),
          ),
        );
      },
      title: widget.showAncestry ? null : priority.title,
      body: widget.showAncestry
          ? PriorityLabel(
              priority: priority,
              fontSize: widget.textStyle?.fontSize,
              height: 1,
              color: widget.monochrome && !isActive ? restingColor : null,
              mutedAncestorColor: widget.monochrome && !isActive
                  ? restingColor
                  : null,
              boldLeaf: widget.boldLeaf,
            )
          : null,
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
      leadingBuilder: (isHovered, hasFocus) => Padding(
        padding: EdgeInsets.only(
          left: leadingH,
          right: buildContext.theme.spacing.sm,
          bottom: 2,
        ),
        child: PriorityNotification(
          unread: widget.unread ?? priority.unread,
          active: widget.active ?? priority.active,
          color: priority.displayColor,
          colorOverride: widget.monochrome ? indicatorColor : null,
        ),
      ),
    );

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
        child: listTile,
      );
    }

    // Touch: open the priority menu via a long-left swipe.
    return Swipeable(
      key: ValueKey(priority.id),
      endLongCommand: ShowPriorityCommands(priority),
      child: listTile,
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
/// - In SelectModal: `itemBuilder: (p) => ListTile(body: PriorityLabel(priority: p))`
/// - In FormSelect: `labelBuilder: (p) => PriorityLabel(priority: p)`
/// - For display: `PriorityLabel(priority: priority, muted: true)` for subdued appearance
class PriorityLabel extends StatelessWidget {
  PriorityLabel({
    List<PriorityAncestor>? ancestors,
    this.priority,
    Priority? context,
    this.onSelect,
    this.fontSize,
    this.height,
    this.muted = false,
    this.color,
    this.mutedAncestorColor,
    this.boldLeaf = false,
    super.key,
  }) : ancestors = (() {
         final computed =
             ancestors ?? priority?.ancestors(context: context) ?? const [];
         return computed;
       }());

  final List<PriorityAncestor> ancestors;
  final Priority? priority;
  final void Function(PriorityId)? onSelect;
  final double? fontSize;
  final double? height;
  final bool muted;
  final Color? color;

  /// Optional color for ancestor crumbs and the separator. When set,
  /// ancestor names + the trailing `>` use this color while the leaf
  /// (current priority) keeps [color]. When unset, ancestors default to
  /// the muted variant of their own theme colors so the leaf stays
  /// visually prominent.
  final Color? mutedAncestorColor;

  /// When true, render ancestor crumbs at regular weight and the leaf
  /// (this priority) at semibold so the leaf reads as the primary label.
  final bool boldLeaf;

  @override
  Widget build(BuildContext context) {
    // Compute display colors for each ancestor (with inheritance)
    ThemeColor currentColor = const ThemeColor.defaultColor();
    final displayColors = <ThemeColor>[];
    for (final ancestor in ancestors) {
      currentColor = ThemeColor(ancestor.color);
      displayColors.add(currentColor);
    }

    // Update current color with priority's color if present
    if (priority?.displayColor != null) {
      currentColor = priority!.displayColor;
    }

    // When ancestors aren't individually tappable, render the whole label as
    // a single Text.rich so ellipsis truncation happens at the end of the
    // line without leaving leftover space between the content and the
    // trailing slot (a multi-Flexible Row layout leaves a visible gap when
    // one Flexible underuses its allocation).
    if (onSelect == null) {
      final resolvedFontSize =
          fontSize ?? context.theme.typography.md.fontSize;
      final ancestorWeight = boldLeaf ? FontWeight.w400 : null;
      final leafWeight = boldLeaf ? FontWeight.w600 : null;
      final spans = <InlineSpan>[];
      for (var i = 0; i < ancestors.length; i++) {
        final ancestor = ancestors[i];
        final isLast = i == ancestors.length - 1;
        final ancestorColor =
            mutedAncestorColor ??
            color ??
            context.colour.colours.fromTheme(displayColors[i], muted: true);
        spans.add(TextSpan(
          text: ancestor.title,
          style: TextStyle(
            color: ancestorColor,
            fontSize: resolvedFontSize,
            height: height,
            fontWeight: ancestorWeight,
          ),
        ));
        if (!isLast || priority != null) {
          spans.add(TextSpan(
            text: Priority.separator,
            style: TextStyle(
              color: mutedAncestorColor ??
                  color ??
                  context.theme.colors.mutedForeground,
              fontSize: resolvedFontSize,
              height: height ?? 1,
              fontWeight: ancestorWeight,
            ),
          ));
        }
      }
      if (priority != null) {
        spans.add(TextSpan(
          text: priority!.title,
          style: TextStyle(
            color: color ??
                context.colour.colours.fromTheme(currentColor, muted: muted),
            fontSize: resolvedFontSize,
            height: height,
            fontWeight: leafWeight,
          ),
        ));
      }
      return Text.rich(
        TextSpan(children: spans),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
    }

    final ancestorWeight = boldLeaf ? FontWeight.w400 : null;
    final leafWeight = boldLeaf ? FontWeight.w600 : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...ancestors.indexed.expand((entry) {
          final i = entry.$1;
          final ancestor = entry.$2;
          final isLast = i == ancestors.length - 1;
          final ancestorColor =
              mutedAncestorColor ??
              color ??
              context.colour.colours.fromTheme(displayColors[i], muted: true);
          final ancestorText = Text(
            ancestor.title,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          );
          return [
            Flexible(
              key: ValueKey('ancestor_${ancestor.id}'),
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: ancestorColor,
                  fontSize: fontSize ?? context.theme.typography.md.fontSize,
                  height: height,
                  fontWeight: ancestorWeight,
                ),
                child: onSelect != null
                    ? Tapable(
                        onTap: () => onSelect!.call(ancestor.id),
                        child: ancestorText,
                      )
                    : ancestorText,
              ),
            ),
            if (!isLast || priority != null)
              DefaultTextStyle(
                key: ValueKey('separator_${ancestor.id}'),
                style: DefaultTextStyle.of(context).style.copyWith(
                  color:
                      mutedAncestorColor ??
                      color ??
                      context.theme.colors.mutedForeground,
                  fontSize: fontSize ?? context.theme.typography.md.fontSize,
                  height: height ?? 1,
                  fontWeight: ancestorWeight,
                ),
                child: Text(Priority.separator),
              ),
          ];
        }),
        if (priority != null)
          Flexible(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color:
                    color ??
                    context.colour.colours.fromTheme(
                      currentColor,
                      muted: muted,
                    ),
                fontSize: fontSize ?? context.theme.typography.md.fontSize,
                height: height,
                fontWeight: leafWeight,
              ),
              child: Text(
                priority!.title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
      ],
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
                fontSize: context.theme.typography.sm.fontSize,
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
