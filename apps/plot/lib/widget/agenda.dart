import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/analytics/tracker.dart' show EventObject, EventAction;
import 'package:plot/command/command.dart';
import 'package:plot/state/agenda_model.dart';
// The store also exports a `PriorityBlock` (the Drift store wrapper for
// priority_block rows). In this file we only need the agenda's UI block,
// so hide the store name to disambiguate `block is PriorityBlock`.
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/widget.dart';

/// Width of the leading column: max of the widest time string and the
/// widest duration string (both at sm font), plus horizontal padding.
/// The gutter holds time on row 1 and duration on row 2 — sizing it to
/// the longest of either keeps the rest of the agenda aligned.
double agendaLeadingWidth(BuildContext context) {
  final isWide = context.isMultiPanel;
  final maxTimeText = isWide ? '12:55 pm' : '12:55p';
  final smSize = context.theme.typography.sm.fontSize;
  final timeWidth = (TextPainter(
    text: TextSpan(
      text: maxTimeText,
      style: TextStyle(fontSize: smSize),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout()).width;
  const maxDurationText = '23h 59m';
  final durationWidth = (TextPainter(
    text: TextSpan(
      text: maxDurationText,
      style: TextStyle(fontSize: smSize),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout()).width;
  final textWidth = timeWidth > durationWidth ? timeWidth : durationWidth;
  final pad = context.theme.spacing.sm;
  return textWidth + pad * 2;
}

class AgendaTile extends StatelessWidget {
  const AgendaTile({
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.isNext = false,
    this.thread,
    this.focusNode,
    this.text,
    this.scheduleAt,
    this.block,
    this.parentBlockId,
    this.sourceDate,
    this.sourcePeriodStart,
    this.parentBlockVisibleCount,
    this.selected = true,
    super.key,
  });

  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final bool isNext;
  final Thread? thread;
  final FocusNode? focusNode;
  final String? text;
  final DateTime? scheduleAt;

  /// When set, render a combined block header for this [AgendaBlock]'s
  /// priority breadcrumb plus a priority-tinted background.
  final AgendaBlock? block;

  /// Whether this tile belongs to the user's current priority context.
  /// Selected block headers carry the priority-tinted background;
  /// unselected ones drop the tint and render on the plain background
  /// so the agenda reads as one neutral list with the active priority's
  /// blocks visually grouped together.
  final bool selected;

  /// Id of the [AgendaBlock] this header introduces, used as the drag
  /// payload's identifier. When non-null and the header is otherwise
  /// draggable (a non-event block in the current priority), the header
  /// becomes a [BlockDragPayload] source.
  final String? parentBlockId;

  /// Source [Date] of the block, threaded into the [BlockDragPayload]
  /// so the drop dispatch can detect cross-date moves.
  final Date? sourceDate;

  /// Source period anchor of the block (gap start, or null for blocks
  /// above any gap). Drives same-period vs cross-period detection in
  /// the drop dispatch.
  final DateTime? sourcePeriodStart;

  /// Visible thread row count for this block (after collapse rules).
  /// Threaded into the [BlockDragPayload] so [BlockDropZone]s can size
  /// themselves to the source block's height.
  final int? parentBlockVisibleCount;

  @override
  Widget build(BuildContext context) {
    if (block != null) {
      return _BlockHeader(
        block: block!,
        dateTimeRange: dateTimeRange,
        thread: thread,
        now: now,
        isNext: isNext,
        parentBlockId: parentBlockId,
        sourceDate: sourceDate,
        sourcePeriodStart: sourcePeriodStart,
        parentBlockVisibleCount: parentBlockVisibleCount,
        selected: selected,
      );
    }
    // Determine what to show in the center
    String? centerText = text;
    // Split date into weekday, month name, and day number for centered
    // rendering.
    String? dateWeekday;
    String? dateMonth;
    String? dateDay;
    if (date != null) {
      // Centered "Weekday, Month Day" using the full names. Computed even
      // when [text] or [dateTimeRange] is also set so the date header
      // can always render its primary label.
      dateWeekday = date!.format(format: 'EEEE');
      dateDay = date!.format(format: 'd');
      dateMonth = date!.year == Date.today().year
          ? date!.format(format: 'MMMM')
          : date!.format(format: 'MMMM yyyy');
    } else if (centerText == null && dateTimeRange != null) {
      // Show time from DateTimeRange
      final timeOfDay = dateTimeRange!.start?.toTimeOfDay();
      if (timeOfDay != null && timeOfDay.isMidnight != true) {
        centerText = context.isMultiPanel
            ? timeOfDay.formatShort(context)
            : timeOfDay.formatNarrow(context);
      }
    }

    // Determine if this is the last gap of the day (until midnight)
    bool isLastGapOfDay = false;
    if (dateTimeRange != null &&
        thread == null && // It's a gap, not a scheduled event
        dateTimeRange!.end != null) {
      // Check if the end time is at midnight (start of next day)
      final endTime = dateTimeRange!.end!;
      isLastGapOfDay =
          endTime.hour == 0 && endTime.minute == 0 && endTime.second == 0;
    }

    // Determine duration text
    String? durationText;
    if (dateTimeRange != null &&
        dateTimeRange!.duration?.inSeconds != null &&
        dateTimeRange!.duration!.inSeconds > 0 &&
        !isLastGapOfDay &&
        !now) {
      durationText = dateTimeRange!.duration!.format();
    }

    // No priority-context tint anymore — the universal agenda no longer
    // privileges a single priority for fallback time labels.
    final nowColor = context.theme.colors.mutedForeground;

    final textColor = now ? nowColor : context.theme.colors.mutedForeground;

    // Detect gap headers (time gaps between scheduled events).
    // The now flag indicates the current time position but doesn't change
    // that this is a gap header — it only affects styling (accent color).
    final isGapHeader = thread == null && dateTimeRange != null && date == null;

    // Use sm font size throughout the agenda left column so time labels
    // and section headings read at the same weight as date headers and
    // the activity feed section markers.
    final fontSize = context.theme.typography.sm.fontSize;

    // Determine which command to use
    CommandWrapper? command;

    // Check if this header represents a past time
    final isPast =
        date != null && date!.isBefore(Date.today()) ||
        dateTimeRange?.end != null && dateTimeRange!.end!.isBefore(Time.now());

    // For headers with scheduleAt (not in the past)
    if (!isPast && (scheduleAt != null || thread?.at != null)) {
      // If this header has an associated event activity, use RescheduleEvent
      if (thread != null && thread!.at != null) {
        command = CommandWrapper(
          RescheduleEvent(
            thread!,
            showPrioritySelector: true,
            priorityBloc: context.read<PriorityBloc>(),
          ),
          icon: Value(null),
        );
      }
    }

    final verticalMargin = isGapHeader
        ? 0.0
        : date != null
        ? context.theme.spacing.xl
        : context.theme.spacing.md;

    // Date headers: simple container with darkened background, no ListTile needed
    if (date != null) {
      final headerBg = context.colour.headerBackground;
      final smSize = context.theme.typography.sm.fontSize;

      // "Weekday  Day  Month" with the day number perfectly centered.
      // Two equal-width Expanded halves sit on either side of the day
      // number — weekday right-aligned in the left half, month
      // left-aligned in the right half — so the day number stays at the
      // absolute horizontal center regardless of weekday/month width.
      // Weekday and month are muted; the day number is foreground.
      final mutedStyle = TextStyle(
        color: context.theme.colors.mutedForeground,
        fontSize: smSize,
        fontWeight: FontWeight.w500,
      );
      final dayStyle = TextStyle(
        color: context.theme.colors.foreground,
        fontSize: smSize,
        fontWeight: FontWeight.w600,
      );
      final spacing = context.theme.spacing;
      final child = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: spacing.sm),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  dateWeekday!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mutedStyle,
                ),
              ),
            ),
          ),
          Text(dateDay!, style: dayStyle),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: spacing.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dateMonth!.trimLeft(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mutedStyle,
                ),
              ),
            ),
          ),
        ],
      );

      return Container(
        color: headerBg,
        padding: EdgeInsets.symmetric(vertical: context.theme.spacing.lg),
        child: child,
      );
    }

    // Gap/event time headers: centered time, rendered outside ListTile
    // to match date header centering
    if (isGapHeader || (!now && date == null && centerText != null)) {
      final veryMuted = context.theme.plotColors.veryMuted;
      final contentColor = isGapHeader ? veryMuted : textColor;
      final timeStyle = TextStyle(color: contentColor, fontSize: fontSize);

      // Match the ThreadWidget time position: the time right edge
      // aligns with the logo right edge (= agendaLeadingWidth).
      final timeColWidth = agendaLeadingWidth(context);

      final Widget child;
      if (centerText != null) {
        final spacing = context.theme.spacing;
        if (dateTimeRange == null) {
          // Plain text section heading (e.g. Activity tab "Today",
          // "New", "Scheduled", "Done") — center, not in the time column.
          child = Center(
            child: Text(
              centerText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: timeStyle,
            ),
          );
        } else {
          // Match the ListTile's right padding so duration aligns with
          // the thread tag button icons.
          final isWide = context.isMultiPanel;
          child = Padding(
            padding: EdgeInsets.only(
              right: isWide
                  ? spacing.lg
                  : context.theme.buttonStyles.ghost.md.iconContentStyle.padding
                        .resolve(TextDirection.ltr)
                        .right,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: timeColWidth,
                  child: Padding(
                    padding: EdgeInsets.only(right: spacing.sm),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        centerText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: timeStyle,
                      ),
                    ),
                  ),
                ),
                if (durationText != null)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        durationText,
                        style: TextStyle(color: veryMuted, fontSize: fontSize),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
      } else {
        final double textHeight = (TextPainter(
          text: TextSpan(
            text: "A",
            style: TextStyle(fontSize: fontSize),
          ),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout()).height;
        child = SizedBox(height: textHeight);
      }

      // Text-only section headings (e.g. Activity tab "Today"/"New"/...)
      // share the unified darker section-header background with agenda
      // date headers and PrioritiesPage section headers — a single
      // Container carries the full md+xs vertical padding so the tinted
      // band reaches all the way around the text.
      // Empty gap headers (no priority) keep that same background so they
      // read as a neutral time marker rather than a priority block.
      final isTextOnlyHeading = !isGapHeader && dateTimeRange == null;
      Widget result;
      if (isTextOnlyHeading) {
        result = Container(
          color: context.colour.headerBackground,
          padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
          child: child,
        );
      } else {
        result = Container(
          color: isGapHeader ? context.colour.headerBackground : null,
          padding: EdgeInsets.symmetric(
            vertical: isGapHeader
                ? context.theme.spacing.xs
                : context.theme.spacing.sm,
          ),
          child: child,
        );
        if (!isGapHeader) {
          result = Padding(
            padding: EdgeInsets.symmetric(vertical: verticalMargin),
            child: result,
          );
        }
      }

      final cmd = command;
      if (cmd != null) {
        result = GestureDetector(onTap: () => cmd.run(context), child: result);
      }

      return result;
    }

    // Now event headers: just render the accent-colored time label
    // (elapsed/remaining is now shown in ThreadWidget)
    if (now && dateTimeRange != null && thread != null) {
      final timeColWidth = agendaLeadingWidth(context);
      final timeOfDay = dateTimeRange!.start?.toTimeOfDay();
      final timeText = timeOfDay != null && !timeOfDay.isMidnight
          ? (context.isMultiPanel
                ? timeOfDay.formatShort(context)
                : timeOfDay.formatNarrow(context))
          : null;

      if (timeText != null) {
        Widget result = Padding(
          padding: EdgeInsets.symmetric(vertical: verticalMargin),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
            child: SizedBox(
              width: timeColWidth,
              child: Padding(
                padding: EdgeInsets.only(right: context.theme.spacing.sm),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    timeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: nowColor, fontSize: fontSize),
                  ),
                ),
              ),
            ),
          ),
        );

        final cmd = command;
        if (cmd != null) {
          result = GestureDetector(
            onTap: () => cmd.run(context),
            child: result,
          );
        }
        return result;
      }
    }

    // Fallback: empty header with spacing
    final double textHeight = (TextPainter(
      text: TextSpan(
        text: "A",
        style: TextStyle(fontSize: fontSize),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout()).height;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalMargin),
      child: SizedBox(height: textHeight),
    );
  }
}

/// Combined block header: block priority's breadcrumb in the main area,
/// optional time on the left for gap/event blocks, and event metadata
/// (RSVP, in-progress timing, countdown, duration) on the right.
/// Background is the priority's tinted color; foreground uses the
/// priority's accent for contrast. Stateful because in-progress events
/// need a per-minute timer to refresh elapsed/remaining counters.
class _BlockHeader extends StatefulWidget {
  const _BlockHeader({
    required this.block,
    required this.dateTimeRange,
    required this.thread,
    required this.now,
    required this.isNext,
    required this.parentBlockId,
    required this.sourceDate,
    required this.sourcePeriodStart,
    required this.parentBlockVisibleCount,
    required this.selected,
  });

  final AgendaBlock block;
  final DateTimeRange? dateTimeRange;
  final Thread? thread;
  final bool now;
  final bool isNext;
  final String? parentBlockId;
  final Date? sourceDate;
  final DateTime? sourcePeriodStart;
  final int? parentBlockVisibleCount;

  /// True when this header belongs to the user's current priority. Drives
  /// the priority-tinted background — unselected blocks render on the
  /// plain background so the user's chosen priority visually groups
  /// against everything else.
  final bool selected;

  Priority get priority => block.priority;

  @override
  State<_BlockHeader> createState() => _BlockHeaderState();
}

class _BlockHeaderState extends State<_BlockHeader> {
  Timer? _tick;
  BlockDragController? _dragController;
  bool _isHovered = false;

  /// Live pending-duration snapshot for [PriorityBlock] headers.
  /// Subscribed in [initState]/[didUpdateWidget] so the gutter label and
  /// the hover ± bump buttons read the same value without each
  /// instantiating their own [StreamSubscription]. Wrapped in
  /// [PriorityPendingDisplay] (rather than a bare `Duration?`) so a
  /// post-emission `null` — the user just cleared the value — is
  /// distinguishable from "subscription hasn't emitted yet". Without
  /// that distinction the gutter would fall back to the agenda model's
  /// stale [PriorityBlock.cascadeDuration] after a clear and the user
  /// would see the just-removed value reappear.
  StreamSubscription<PriorityPendingDisplay>? _pendingSub;
  PriorityPendingDisplay? _pendingDisplay;

  // Touch: short swipes on the block header bump the editable duration
  // by ±15m (right = +, left = −) — the hover ± buttons are mouse-only.
  // See [_wrapSwipe]. Long-swipe slots are still free for a future
  // block-menu command (TODO(agenda-menu)).

  static const _swipeBumpStep = Duration(minutes: 15);

  /// First-add default for a priority block's pending duration. A bump
  /// from `null` lands here directly instead of going through one
  /// [_swipeBumpStep] — matches the same 30m default the agenda's
  /// drop-into-gap path applies, so "Add planned time" produces the
  /// same starting size regardless of how the user invoked it.
  static const _firstAddDuration = Duration(minutes: 30);

  /// Minimum non-zero duration. A subtract that would land below this
  /// clears the pending value entirely (returns null) rather than
  /// leaving a sub-step remainder.
  static const _minimumDuration = Duration(minutes: 15);

  /// True when this block header is itself a drag source (a non-event
  /// block with a known parent block id). Outside-priority gating is
  /// no longer relevant in the universal agenda — every priority's
  /// blocks are equally first-class.
  bool get _isDraggable =>
      widget.parentBlockId != null && widget.thread == null;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
    _subscribePending();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = BlockDragScope.maybeOf(context);
    if (newController != _dragController) {
      _dragController?.removeListener(_onDragChanged);
      _dragController = newController;
      _dragController?.addListener(_onDragChanged);
    }
  }

  @override
  void didUpdateWidget(_BlockHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.now != widget.now || oldWidget.isNext != widget.isNext) {
      _tick?.cancel();
      _scheduleTick();
    }
    if (oldWidget.priority.id != widget.priority.id ||
        _blockHasEditablePending(oldWidget.block) !=
            _blockHasEditablePending(widget.block)) {
      _pendingSub?.cancel();
      _pendingDisplay = null;
      _subscribePending();
    }
  }

  /// True for blocks whose lead priority owns an editable pending
  /// duration in the gutter — both standalone [PriorityBlock]s and
  /// [GapBlock]s that have promoted a priority into their header
  /// (either via threads or a cascade-merged slice).
  /// Empty / no-priority gaps stay read-only.
  static bool _blockHasEditablePending(AgendaBlock block) {
    if (block is PriorityBlock) return true;
    if (block is GapBlock &&
        (block.threads.isNotEmpty || block.cascadeDuration != null)) {
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pendingSub?.cancel();
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
  }

  void _subscribePending() {
    if (!_blockHasEditablePending(widget.block)) return;
    _pendingSub = NowBloc.watchPendingDisplay(widget.priority.id).listen((d) {
      if (!mounted) return;
      setState(() => _pendingDisplay = d);
    });
  }

  void _onDragChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _scheduleTick() {
    if (!widget.now && !widget.isNext) return;
    final now = Time.now();
    final secondsUntilNextMinute = 60 - now.second;
    _tick = Timer(Duration(seconds: secondsUntilNextMinute + 1), () {
      if (!mounted) return;
      setState(() {});
      _scheduleTick();
    });
  }

  /// [GlobalKey] on the source row so the controller can read its
  /// natural [RenderBox] bounds at drag start (before `childWhenDragging`
  /// shrinks the layout slot).
  final GlobalKey _sourceKey = GlobalKey();

  void _onDragStarted(BlockDragPayload payload) {
    _dragController?.start(
      payload,
      sourceContextProvider: () => _sourceKey.currentContext ?? context,
    );
  }

  void _onDragEnded() {
    // Cancel path (e.g. ESC, lost pointer) — do not dispatch.
    _dragController?.end(dispatch: false);
  }

  /// Drag-end from the underlying [Draggable] / [LongPressDraggable].
  /// The controller dispatches via its current active target — set by
  /// the last `onDragUpdate` — and noops when no slot is active (e.g.
  /// the user released right where the source was).
  void _onDragEndedWith(DraggableDetails details) {
    _dragController?.end();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragController?.updatePointer(details.globalPosition);
  }

  /// Renders the block header row. When [trailingHandle] is non-null
  /// (touch devices) the handle is laid out as the rightmost child so
  /// the priority-tinted background extends beneath it; the row's own
  /// right padding is dropped because the handle's internal padding
  /// supplies the trailing visual inset.
  Widget _buildRow(BuildContext context, {Widget? trailingHandle}) {
    final block = widget.block;
    final priority = block.priority;
    final dateTimeRange = widget.dateTimeRange;
    final thread = widget.thread;

    final fg = context.colour.colours.fromTheme(priority.displayColor);
    final mutedFg = context.colour.colours.fromTheme(
      priority.displayColor,
      muted: true,
    );
    final bg = widget.selected
        ? context.colour.colours.backgroundFromTheme(priority.displayColor)
        : _isHovered
        ? context.colour.editableBackground
        : context.colour.background;
    final spacing = context.theme.spacing;
    // Primary line (priority breadcrumb) reads at the same size as
    // thread titles in the activity feed; secondary line (summary,
    // time, duration, RSVP, active-timing) sits one step below for
    // hierarchy without crowding.
    final primarySize = context.theme.typography.md.fontSize ?? 15;
    final secondarySize = context.theme.typography.sm.fontSize ?? 13;

    final hasTime = dateTimeRange != null;
    final timeOfDay = dateTimeRange?.start?.toTimeOfDay();
    final timeText = hasTime && timeOfDay != null && !timeOfDay.isMidnight
        ? (context.isMultiPanel
              ? timeOfDay.formatShort(context)
              : timeOfDay.formatNarrow(context))
        : null;

    final summary = block.summaryLine;

    // For event blocks the summary's first title is the event itself —
    // render it in the priority's foreground color so it reads as the
    // primary label, with any associated threads following in the
    // neutral muted color used for non-event block summaries.
    final mutedColor = context.theme.colors.mutedForeground;
    final TextSpan summarySpan;
    if (block is EventBlock) {
      final eventTitle = block.event.displayTitle;
      final associated = block.associated
          .map((t) => t.displayTitle)
          .where((s) => s.isNotEmpty)
          .toList();
      summarySpan = TextSpan(
        children: [
          if (eventTitle.isNotEmpty)
            TextSpan(
              text: eventTitle,
              style: TextStyle(color: context.theme.colors.foreground),
            ),
          if (eventTitle.isNotEmpty && associated.isNotEmpty)
            TextSpan(
              text: ' · ',
              style: TextStyle(color: mutedColor),
            ),
          if (associated.isNotEmpty)
            TextSpan(
              text: associated.join(' · '),
              style: TextStyle(color: mutedColor),
            ),
        ],
      );
    } else {
      summarySpan = TextSpan(
        text: summary,
        style: TextStyle(color: mutedColor),
      );
    }

    // Row 2 trailing widget: RSVP summary, right-padded so its visible
    // edge lands at the same x as the right edge of the content area.
    Widget? row2Trailing;
    if (thread != null && thread.hasOtherAttendees) {
      row2Trailing = RsvpSummary(activity: thread, fontSize: secondarySize);
    }

    final timeColWidth = agendaLeadingWidth(context);

    // Right padding lands trailing items at the agenda's outer edge.
    final isWide = context.isMultiPanel;
    final iconPad = context.theme.buttonStyles.ghost.md.iconContentStyle.padding
        .resolve(TextDirection.ltr);
    final rightPad = isWide ? spacing.lg : iconPad.right;

    // For an in-progress event, replace the static duration label in
    // gutter row 2 with the remaining time so it counts down toward 0.
    Widget? gutterRow2;
    if (widget.now && thread?.at?.end != null) {
      final currentTime = Time.now();
      final end = thread!.at!.end!;
      if (end.isAfter(currentTime)) {
        final remaining = (end.difference(currentTime).inSeconds / 60).ceil();
        gutterRow2 = Text(
          Duration(minutes: remaining).format(),
          style: TextStyle(
            fontSize: secondarySize,
            color: mutedColor,
            height: 1,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }
    } else if (_blockHasEditablePending(block)) {
      // Priority blocks and gap blocks that have promoted a priority
      // into their header both surface the priority's pending in the
      // gutter. Prefer the live value from [NowBloc.watchPendingDisplay]
      // so an active session's countdown shows; once the subscription
      // has emitted, trust its value (including an explicit null after a
      // ± clear) — falling back to the agenda model's stale
      // `cascadeDuration` would leave the gutter showing the pre-clear
      // number even though the underlying row is gone. When the
      // priority has no pending and the block is a [GapBlock], the
      // gap's own range duration takes over (preserves the legacy gap
      // time-marker behaviour).
      final slice = block is PriorityBlock
          ? block.cascadeDuration
          : (block as GapBlock).cascadeDuration;
      final pending = _pendingDisplay != null
          ? _pendingDisplay!.duration
          : slice;
      Duration? displayed = pending;
      if (displayed == null && block is GapBlock) {
        final dur = dateTimeRange?.duration;
        if (dur != null && dur.inSeconds > 0) displayed = dur;
      }
      if (displayed != null) {
        gutterRow2 = Text(
          _formatDuration(displayed),
          style: TextStyle(
            fontSize: secondarySize,
            color: mutedColor,
            height: 1,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }
    } else {
      final dur = dateTimeRange?.duration;
      if (dur != null && dur.inSeconds > 0) {
        gutterRow2 = Text(
          dur.format(),
          style: TextStyle(
            fontSize: secondarySize,
            color: mutedColor,
            height: 1,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      }
    }

    // Row 2 renders whenever ANY column has content for it: the gutter
    // duration label, the summary text, or a row-2 trailing widget. The
    // empty side (e.g. summary text on a duration-only [GapBlock]) just
    // renders a placeholder so both columns stay vertically aligned.
    final hasSecondRow =
        gutterRow2 != null || summary.isNotEmpty || row2Trailing != null;

    // Hover bump callback: events update the thread's duration; priority
    // blocks update the priority's total pending (slice-aware — see
    // [_applyPriorityBump]). Null when no editable duration is exposed
    // (e.g. GapBlock headers without a thread). Shared with [_wrapSwipe]
    // so the touch swipe gestures and the desktop hover ± buttons
    // operate on the same underlying value/callback.
    final (currentDuration, onBumpDuration) = _computeBumpInfo(context);

    final innerRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gutter: time (row 1) + duration / active timing (row 2).
        // Both right-aligned within the gutter so the values stack
        // cleanly. Duration uses xs font; since durations never have
        // descenders, the row 2 box can hug the glyph height.
        SizedBox(
          width: timeColWidth,
          child: Padding(
            padding: EdgeInsets.only(right: spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  height: primarySize,
                  child: timeText != null
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            timeText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.theme.colors.foreground,
                              fontSize: secondarySize,
                              height: 1,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (hasSecondRow) ...[
                  SizedBox(height: spacing.sm),
                  SizedBox(
                    height: secondarySize * 1.25,
                    child: gutterRow2 != null
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: gutterRow2,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: primarySize,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PriorityLabel(
                    priority: priority,
                    color: fg,
                    mutedAncestorColor: mutedFg,
                    fontSize: secondarySize,
                    height: 1,
                  ),
                ),
              ),
              if (hasSecondRow) ...[
                SizedBox(height: spacing.sm),
                SizedBox(
                  height: secondarySize * 1.25,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text.rich(
                          summarySpan,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: secondarySize, height: 1),
                        ),
                      ),
                      if (row2Trailing != null) ...[
                        SizedBox(width: spacing.sm),
                        row2Trailing,
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    // Float the hover +/− buttons centred vertically over the whole
    // block (both rows). Matches the original [_PendingDurationControl]
    // float behaviour while keeping the new [ThreadWidget]-style icon
    // buttons and edge-fade gradient.
    final Widget inner = onBumpDuration == null
        ? innerRow
        : Stack(
            alignment: Alignment.centerRight,
            clipBehavior: Clip.none,
            children: [
              innerRow,
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _BlockHoverDurationButtons(
                  current: currentDuration,
                  onChanged: onBumpDuration,
                  background: bg,
                  visible: _isHovered,
                ),
              ),
            ],
          );

    return Container(
      color: bg,
      padding: EdgeInsets.only(
        top: spacing.md,
        bottom: spacing.md,
        right: trailingHandle != null ? 0 : rightPad,
      ),
      child: trailingHandle == null
          ? inner
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: inner),
                trailingHandle,
              ],
            ),
    );
  }

  /// Returns the editable duration value and the bump callback for this
  /// block: events update the thread's duration; priority blocks update
  /// whichever row is currently producing the displayed value
  /// (see [_applyPriorityBump]). Both elements are `null` when no
  /// editable duration is exposed (e.g. GapBlock headers without a
  /// thread).
  (Duration?, ValueChanged<Duration?>?) _computeBumpInfo(BuildContext context) {
    final block = widget.block;
    final thread = widget.thread;
    if (thread != null) {
      return (
        widget.dateTimeRange?.duration,
        (newDur) => SetThreadDuration(thread, newDur).run(context),
      );
    }
    if (_blockHasEditablePending(block)) {
      // First frame before the stream emits has no display snapshot —
      // fall back to the agenda model's cascade slice so the gutter still
      // shows something. After the first emission [_pendingDisplay]
      // tracks the live value (and its source); the snapshot's `null`
      // means the bottom of the cascade (no row contributing) and must
      // win over the stale slice, otherwise a fresh clear instantly
      // restages the old value through the bump math.
      final slice = block is PriorityBlock
          ? block.cascadeDuration
          : (block as GapBlock).cascadeDuration;
      final current = _pendingDisplay != null
          ? _pendingDisplay!.duration
          : slice;
      return (
        current,
        (newDur) => _applyPriorityBump(
          priority: block.priority,
          newDisplayed: newDur,
          currentDisplayed: current,
        ),
      );
    }
    return (null, null);
  }

  /// Returns the next value after a swipe-bump.
  ///
  /// * Adding to a null pending lands at [_firstAddDuration] (30m) — the
  ///   single-tap default for "Add planned time" — rather than one
  ///   [_swipeBumpStep] (15m). Subsequent adds proceed in [_swipeBumpStep]
  ///   increments.
  /// * Subtracting from a value at or below [_minimumDuration] clears
  ///   (returns null) so the gutter empties when nothing meaningful is
  ///   left — sub-step remainders aren't useful and would otherwise
  ///   leave fractions lingering after a tap that visually said "15m → 0".
  ///   Above the minimum, subtracting decrements by [_swipeBumpStep].
  Duration? _bumpedDuration(Duration? current, Duration delta) {
    if (!delta.isNegative && (current == null || current <= Duration.zero)) {
      return _firstAddDuration;
    }
    if (delta.isNegative && (current ?? Duration.zero) <= _minimumDuration) {
      return null;
    }
    final next = (current ?? Duration.zero) + delta;
    if (next <= Duration.zero) return null;
    if (next < _minimumDuration) return _minimumDuration;
    return next;
  }

  /// On touch, wrap [child] in a [Swipeable] whose short right/left
  /// gestures add/subtract 15 minutes from the block's editable duration.
  /// Mirrors the hover ± buttons used on desktop. No-op on devices with
  /// a physical keyboard (the hover row is sufficient) or when this
  /// block has no editable duration (e.g. empty gap headers).
  Widget _wrapSwipe(BuildContext context, Widget child) {
    if (hasPhysicalKeyboard()) return child;
    final (current, onBump) = _computeBumpInfo(context);
    if (onBump == null) return child;
    final hasValue = current != null && current.inSeconds > 0;
    final addCmd = _BumpDurationCommand(
      title: hasValue ? 'Add 15 minutes' : 'Add planned time',
      icon: PlotIcon.add,
      onApply: () => onBump(_bumpedDuration(current, _swipeBumpStep)),
    );
    final removeCmd = hasValue
        ? _BumpDurationCommand(
            title: 'Subtract 15 minutes',
            icon: PlotIcon.remove,
            onApply: () => onBump(_bumpedDuration(current, -_swipeBumpStep)),
          )
        : null;
    return Swipeable(startCommand: addCmd, endCommand: removeCmd, child: child);
  }

  /// Apply a ±15m bump to a [PriorityBlock]'s displayed value. Routes
  /// through [NowBloc.applyPendingBump] so the write lands on the same
  /// row the gutter label is reading (active or paused-explicit session
  /// when one is in play, otherwise `priority_block.duration`). Without
  /// this routing a bump on a session-derived display would write to
  /// `priority_block.duration` and the user would see nothing change.
  void _applyPriorityBump({
    required Priority priority,
    required Duration? newDisplayed,
    required Duration? currentDisplayed,
  }) {
    NowBloc.applyPendingBump(
      priorityId: priority.id,
      currentDisplayed: currentDisplayed,
      newDisplayed: newDisplayed,
    );
  }

  /// Builds the floating-feedback widget shown under the pointer during
  /// a block drag. Sized to the source row's actual rendered width so
  /// the feedback keeps the row's shape (rather than expanding to the
  /// full viewport). [DraggedRowFrame] paints the same 1px border the
  /// activity-feed thread drag uses, so block and thread drags read
  /// identically.
  Widget _buildFeedback(BuildContext context, {required double rowWidth}) {
    return DraggedRowFrame(width: rowWidth, child: _buildRow(context));
  }

  /// Wraps [child] in a tap handler that switches the user's current
  /// priority to this block's priority via [ChangeCurrentPriority], and
  /// in a [MouseRegion] that paints a [colour.editableBackground]
  /// background on pointer hover — matching the PriorityPage activity
  /// feed's [ThreadWidget] hover color, which sits a step lighter than
  /// the page background in both light and dark modes. Applies uniformly to priority, gap-with-threads, and
  /// event block headers (the dedicated event row beneath the header
  /// retains its own "open the event" tap target).
  ///
  /// Uses [GestureDetector] so the tap recognizer competes in the
  /// gesture arena with any surrounding [Draggable] / [LongPressDraggable] —
  /// movement past the drag slop hands the pointer to the drag and
  /// suppresses the tap, so a click navigates while a drag reorders.
  ///
  /// `HitTestBehavior.opaque` is required because the row's content is
  /// plain [Text] — [RenderParagraph] without hit-testable spans does
  /// not add itself to hit tests, so a default `deferToChild` detector
  /// would silently miss taps on most of the header. The inner
  /// [_BlockHoverDurationButtons] uses [Button.icon]'s own opaque hit
  /// targets so +/− taps don't bubble up to the row tap-to-open.
  Widget _wrapTapToOpen(Widget child) {
    return MouseRegion(
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final eventThread = widget.thread;
          if (eventThread == null) {
            context.run(
              ChangeCurrentPriority(widget.priority, fromAgenda: true),
            );
            return;
          }
          // Event-headers in the universal agenda live under the
          // default-priority PriorityBloc, so [ChangeCurrentThread]'s
          // "stay on currentPriority" navigation would yank the user
          // onto the default priority instead of the event's. Drive
          // navigation explicitly to the event's priority, set the
          // event as current, and let [ThreadPage] wire `setThread`
          // into the destination [PriorityBloc] on mount.
          context.read<NowBloc>().setCurrentEvent(eventThread);
          // Match the gap-header path: the destination page should open
          // with descendants hidden, since the agenda already rolls them
          // up under each block.
          PriorityBloc.markNextPriorityFromAgenda();
          context.router.navigate(
            PriorityRoute(
              priorityIdString: eventThread.priority.id.toShortString(),
              children: [
                ThreadRoute(threadIdString: eventThread.id.toShortString()),
              ],
            ),
          );
        },
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDraggable) {
      return _wrapTapToOpen(_wrapSwipe(context, _buildRow(context)));
    }

    final payload = BlockDragPayload(
      blockId: widget.parentBlockId!,
      priorityId: widget.priority.id,
      sourceDate: widget.sourceDate,
      sourcePeriodStart: widget.sourcePeriodStart,
      visibleThreadCount: widget.parentBlockVisibleCount ?? 0,
    );

    // While the drag is active the source's slot in the agenda flips
    // between "dimmed in place" (cursor in the source's deadzone) and
    // "collapsed to zero" (cursor over a real drop slot — the source's
    // space has logically moved to that slot, which expands to match).
    // [AnimatedSize] smooths the transition so the swap reads as a
    // gap-following animation, similar to `SliverReorderableList`.
    Widget buildDraggingChild() => ListenableBuilder(
      listenable: _dragController ?? _NullListenable(),
      builder: (context, _) {
        final visible = _dragController?.isSourceVisible ?? true;
        return AnimatedSize(
          duration: kBlockBoundaryAnimDuration,
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: visible
              ? Opacity(opacity: 0.4, child: _buildRow(context))
              : const SizedBox.shrink(),
        );
      },
    );

    // Capture the actual rendered width via LayoutBuilder so the floating
    // feedback can match the source row's shape instead of growing to the
    // full viewport (multi-panel renders the agenda narrower than the
    // window).
    return _wrapTapToOpen(
      LayoutBuilder(
        builder: (context, constraints) {
          final rowWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.of(context).size.width;
          // [Swipeable] nests inside the [LongPressDraggable] so the
          // horizontal drag claims the gesture arena at hit-slop while
          // the long-press still wins the drag — same pattern the
          // activity feed uses. See [_SwipeHorizontalDragRecognizer].
          final source = KeyedSubtree(
            key: _sourceKey,
            child: _wrapSwipe(context, _buildRow(context)),
          );
          final feedback = _buildFeedback(context, rowWidth: rowWidth);
          final childWhenDragging = buildDraggingChild();
          // Desktop (mouse): the whole header row is a Draggable — any
          // click-and-drag starts a block reorder. Pointer hover is
          // unambiguous so we don't need a dedicated handle.
          if (hasPhysicalKeyboard()) {
            return Draggable<BlockDragPayload>(
              data: payload,
              feedback: feedback,
              childWhenDragging: childWhenDragging,
              onDragStarted: () => _onDragStarted(payload),
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEndedWith,
              onDraggableCanceled: (_, _) => _onDragEnded(),
              child: source,
            );
          }
          // Touch: the whole row is a [LongPressDraggable] — the delayed
          // recognizer disambiguates drag from scroll/tap (scroll wins
          // immediate movement, tap wins a quick release, hold past
          // [kLongPressTimeout] starts the drag). Mirrors the activity-
          // feed mobile drag pattern. A plain [Draggable] here would
          // claim the gesture on any small movement, which conflicts
          // with vertical scroll and — in practice on touch — fails to
          // deliver subsequent `onDragUpdate` callbacks to the
          // controller, leaving the agenda without drop placeholders and
          // dropping back to origin on release.
          return LongPressDraggable<BlockDragPayload>(
            data: payload,
            feedback: feedback,
            childWhenDragging: childWhenDragging,
            onDragStarted: () => _onDragStarted(payload),
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEndedWith,
            onDraggableCanceled: (_, _) => _onDragEnded(),
            child: source,
          );
        },
      ),
    );
  }
}

/// No-op [Listenable] used as a fallback when the [BlockDragController]
/// isn't yet available — keeps [ListenableBuilder] happy without any
/// branching in the build method.
class _NullListenable extends Listenable {
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// Format a duration for the gutter label. Differs from
/// [DurationExtension.format] only in that it returns an empty string for
/// zero rather than the en dash sentinel used elsewhere — the gutter
/// already hides the row when no value is present.
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes - h * 60;
  if (h == 0 && m == 0) return '';
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

/// Inline hover +/− stepper for the agenda block header. Mirrors the
/// [ThreadCommands] hover pattern: an [AnimatedOpacity]-wrapped [Row]
/// with a 24-px gradient that fades the row's background up to a solid
/// [ColoredBox] holding the icon buttons, so the controls overlap the
/// priority label without revealing the text underneath.
///
/// [current] is the value the user sees; [onChanged] receives the new
/// duration (null clears it). Both buttons hide when [visible] is false;
/// the − is also hidden when there is nothing to subtract.
class _BlockHoverDurationButtons extends StatelessWidget {
  const _BlockHoverDurationButtons({
    required this.current,
    required this.onChanged,
    required this.background,
    required this.visible,
  });

  final Duration? current;
  final ValueChanged<Duration?> onChanged;
  final Color background;
  final bool visible;

  static const _step = Duration(minutes: 15);

  /// Returns the next value after a +/− press. A subtract on a value at
  /// or below [_step] clears (returns null) — the user pressed − on a
  /// gutter showing 15m or less, which signals "remove this duration"
  /// rather than "shave another 15m off a sub-step remainder".
  Duration? _bumped(Duration delta) {
    if (delta.isNegative && (current ?? Duration.zero) <= _step) return null;
    final next = (current ?? Duration.zero) + delta;
    if (next <= Duration.zero) return null;
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = current != null && current!.inSeconds > 0;
    // Stretch the gradient and the solid background to the parent's
    // full height so the buttons cover any underlying row that would
    // otherwise bleed through, and so the gradient is a real rectangle
    // (a zero-height Container would never paint).
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Gradient fade from transparent to the row's background so
            // the priority label tail dissolves into the buttons.
            Container(
              width: 24,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [background.withValues(alpha: 0), background],
                ),
              ),
            ),
            ColoredBox(
              color: background,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (hasValue)
                    Button.icon(
                      _BumpDurationCommand(
                        title: 'Subtract 15 minutes',
                        icon: PlotIcon.remove,
                        onApply: () => onChanged(_bumped(-_step)),
                      ),
                    ),
                  Button.icon(
                    _BumpDurationCommand(
                      title: hasValue ? 'Add 15 minutes' : 'Add planned time',
                      icon: PlotIcon.add,
                      onApply: () => onChanged(_bumped(_step)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lightweight closure-backed [Command] used by [_BlockHoverDurationButtons]
/// to route +/− taps through [Button.icon] into the parent block header's
/// callback. The callback owns the actual delta math and persistence;
/// this class just forwards `run()` and supplies the icon/title that
/// drive [Button.icon]'s tooltip and glyph.
class _BumpDurationCommand extends Command {
  _BumpDurationCommand({
    required super.title,
    required IconData super.icon,
    required this.onApply,
  }) : super(
         eventObject: EventObject.priority,
         eventAction: EventAction.updated,
       );

  final VoidCallback onApply;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    onApply();
    return const CommandDone();
  }
}
