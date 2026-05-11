import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/duration_control.dart';
import 'package:plot/widget/widget.dart';

/// Width of the leading column: widest possible time string + horizontal padding.
/// Used by both [AgendaTile] gap rows and [ThreadWidget] leading areas.
double agendaLeadingWidth(BuildContext context) {
  final isWide = context.isMultiPanel;
  final maxTimeText = isWide ? '12:55 pm' : '12:55p';
  final fontSize = context.theme.typography.sm.fontSize;
  final textWidth = (TextPainter(
    text: TextSpan(
      text: maxTimeText,
      style: TextStyle(fontSize: fontSize),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout()).width;
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
    // Split date into two parts for center-on-month alignment
    String? dateCenterLeft;
    String? dateMonth;
    String? dateCenterRight;
    if (centerText == null) {
      if (dateTimeRange != null) {
        // Show time from DateTimeRange
        final timeOfDay = dateTimeRange!.start?.toTimeOfDay();
        if (timeOfDay != null && timeOfDay.isMidnight != true) {
          centerText = context.isMultiPanel
              ? timeOfDay.formatShort(context)
              : timeOfDay.formatNarrow(context);
        }
      } else if (date != null) {
        // Show date split into day-of-week and month+day for centered layout
        dateCenterLeft = date!.format(format: 'EEEE');
        dateCenterRight = date!.format(format: 'd');
        dateMonth = date!.year == Date.today().year
            ? date!.format(format: 'MMM')
            : date!.format(format: 'MMM yyyy');
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
      final veryMuted = context.theme.plotColors.veryMuted;

      final Widget child;
      if (dateCenterLeft != null) {
        // Gutter holds "[Mon] [24]" right-aligned on a single sm line —
        // short month name in veryMuted, date number in foreground. The
        // main area renders the day-of-week (sm, veryMuted) on the same
        // baseline.
        final timeColWidth = agendaLeadingWidth(context);
        final spacing = context.theme.spacing;
        final gutter = Padding(
          padding: EdgeInsets.only(right: spacing.sm),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: smSize, fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: dateMonth!.trimLeft(),
                    style: TextStyle(color: veryMuted),
                  ),
                  const TextSpan(text: ' '),
                  TextSpan(
                    text: dateCenterRight!,
                    style: TextStyle(color: context.theme.colors.foreground),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        child = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: timeColWidth, child: gutter),
            Expanded(
              child: Text(
                dateCenterLeft,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: veryMuted, fontSize: smSize),
              ),
            ),
          ],
        );
      } else {
        // Relative date label ("Yesterday", "2 days ago", etc.)
        child = Center(
          child: Text(
            centerText!,
            style: TextStyle(color: veryMuted, fontSize: smSize),
          ),
        );
      }

      return Container(
        color: headerBg,
        padding: EdgeInsets.symmetric(vertical: context.theme.spacing.md),
        child: child,
      );
    }

    // Gap/event time headers: centered time, rendered outside ListTile
    // to match date header centering
    if (isGapHeader || (!now && date == null && centerText != null)) {
      final veryMuted = context.theme.plotColors.veryMuted;
      final contentColor = isGapHeader
          ? context.theme.colors.mutedForeground
          : textColor;
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
                      alignment: Alignment.centerRight,
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
                ? context.theme.spacing.md
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
  }

  @override
  void dispose() {
    _tick?.cancel();
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
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
    final hasUnread = block.hasUnread;

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

    // Row 1 trailing widget: static duration (with hover stepper) or
    // active-timing display ("↑Xm / Ym") while the event is in progress.
    Widget? row1Trailing;
    if (widget.now && thread?.at?.start != null) {
      final currentTime = Time.now();
      final start = thread!.at!.start!;
      final end = thread.at!.end;
      final elapsed = currentTime.difference(start).inMinutes;
      final parts = <Widget>[];
      if (elapsed >= 1) {
        parts.add(
          Text(
            '↑${Duration(minutes: elapsed).format()}',
            style: TextStyle(color: fg, fontSize: secondarySize, height: 1),
          ),
        );
      }
      if (end != null && end.isAfter(currentTime)) {
        final remaining = (end.difference(currentTime).inSeconds / 60).ceil();
        if (parts.isNotEmpty) parts.add(SizedBox(width: spacing.xs));
        parts.add(
          Text(
            '/ ${Duration(minutes: remaining).format()}',
            style: TextStyle(
              color: mutedFg,
              fontSize: secondarySize,
              height: 1,
            ),
          ),
        );
      }
      if (parts.isNotEmpty) {
        // 6px right padding mirrors [DurationControl]'s intrinsic right
        // padding so the active-timing text right-aligns at the same x
        // as a static duration would.
        row1Trailing = Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: parts),
        );
      }
    } else {
      // Only render the duration affordance when there's a duration to
      // show or an event thread the user can edit. For non-event blocks
      // (no thread, no time) an empty [DurationControl] would otherwise
      // eat ~30px of the priority label's width and force premature
      // truncation of the breadcrumb.
      final dur = dateTimeRange?.duration;
      final hasDuration = dur != null && dur.inSeconds > 0;
      if (hasDuration || thread != null) {
        row1Trailing = DurationControl(
          value: dur,
          onChanged: thread == null
              ? null
              : (newDur) => SetThreadDuration(thread, newDur).run(context),
          foreground: context.theme.colors.mutedForeground,
        );
      }
    }

    // Row 2 trailing widget: RSVP summary, padded 6px on the right so
    // its visible right edge lands at the same x as the duration above
    // (which sits 6px inset within [DurationControl]).
    Widget? row2Trailing;
    if (thread != null && thread.hasOtherAttendees) {
      row2Trailing = Padding(
        padding: const EdgeInsets.only(right: 6),
        child: RsvpSummary(activity: thread, fontSize: secondarySize),
      );
    }

    final timeColWidth = agendaLeadingWidth(context);

    // Right padding mirrors gap rows so trailing items terminate at the
    // same x as gap durations. We subtract 6 to absorb [DurationControl]'s
    // intrinsic right-side text padding — every trailing widget then
    // ensures its visible right edge lands at (containerFullWidth -
    // rightPad), matching gap row duration alignment.
    final isWide = context.isMultiPanel;
    final rightPad = isWide
        ? spacing.lg
        : context.theme.buttonStyles.ghost.md.iconContentStyle.padding
              .resolve(TextDirection.ltr)
              .right;

    // Unread dot color: priority accent at reduced alpha to mirror
    // [PriorityNotification]'s _DotPainter treatment.
    final unreadColor = fg.withValues(alpha: 0.7);

    final hasSecondRow = summary.isNotEmpty || row2Trailing != null;

    final inner = Stack(
      alignment: Alignment.center,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Gutter: time (row 1) + unread dot (row 2). The unread
            // dot lives in the gutter rather than the main content so
            // it doesn't push the summary text and so multiple
            // priority blocks with unread state read as a vertical
            // column of indicators.
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
                                  color: context.theme.colors.mutedForeground,
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
                        child: hasUnread
                            ? Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: unreadColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
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
                    child: Row(
                      children: [
                        Expanded(
                          child: PriorityLabel(
                            priority: priority,
                            color: fg,
                            mutedAncestorColor: mutedFg,
                            fontSize: secondarySize,
                            height: 1,
                          ),
                        ),
                        if (row1Trailing != null) ...[
                          SizedBox(width: spacing.md),
                          row1Trailing,
                        ],
                      ],
                    ),
                  ),
                  if (hasSecondRow) ...[
                    SizedBox(height: spacing.sm),
                    SizedBox(
                      height: secondarySize * 1.25,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text.rich(
                              summarySpan,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: secondarySize,
                                height: 1.25,
                              ),
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
        ),
      ],
    );

    return Container(
      color: bg,
      padding: EdgeInsets.only(
        top: spacing.md,
        bottom: spacing.md,
        right: trailingHandle != null ? 0 : rightPad - 6,
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
  /// [DurationControl] uses its own opaque gesture detectors so taps
  /// on the duration strip do not bubble up here.
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
        onTap: () => context.run(ChangeCurrentPriority(widget.priority)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDraggable) {
      return _wrapTapToOpen(_buildRow(context));
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
          // Desktop (mouse): the whole header row is a Draggable — any
          // click-and-drag starts a block reorder. Pointer hover is
          // unambiguous so we don't need a dedicated handle.
          if (hasPhysicalKeyboard()) {
            final source = KeyedSubtree(
              key: _sourceKey,
              child: _buildRow(context),
            );
            return Draggable<BlockDragPayload>(
              data: payload,
              feedback: _buildFeedback(context, rowWidth: rowWidth),
              childWhenDragging: buildDraggingChild(),
              onDragStarted: () => _onDragStarted(payload),
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEndedWith,
              onDraggableCanceled: (_, _) => _onDragEnded(),
              child: source,
            );
          }
          // Touch: distinguishing a drag from a vertical scroll is
          // impossible if the whole row is the drag source, so we mirror
          // the [PriorityWidget] / [ThreadWidget] reorder UX — the row
          // itself stays scrollable / tappable, and only a trailing
          // [DragHandle] starts the block drag. Anchored at the source
          // row's original top-left so the floating feedback overlays
          // where the row was, then follows the finger from there.
          final handle = Draggable<BlockDragPayload>(
            data: payload,
            feedback: _buildFeedback(context, rowWidth: rowWidth),
            dragAnchorStrategy: _sourceTopLeftAnchor,
            childWhenDragging: const DragHandle(),
            onDragStarted: () => _onDragStarted(payload),
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEndedWith,
            onDraggableCanceled: (_, _) => _onDragEnded(),
            child: const DragHandle(),
          );
          // Row body responds to drag state directly: at rest it shows
          // the row + handle inline; while THIS block is being dragged
          // it dims/collapses the same way the desktop `childWhenDragging`
          // does. Wrapped in `_sourceKey` so the controller can still
          // read the source's natural bounds at drag start.
          return KeyedSubtree(
            key: _sourceKey,
            child: ListenableBuilder(
              listenable: _dragController ?? _NullListenable(),
              builder: (context, _) {
                final ctrl = _dragController;
                final isThis =
                    ctrl != null &&
                    ctrl.draggingBlockId == widget.parentBlockId;
                if (!isThis) {
                  return _buildRow(context, trailingHandle: handle);
                }
                final visible = ctrl.isSourceVisible;
                return AnimatedSize(
                  duration: kBlockBoundaryAnimDuration,
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: visible
                      ? Opacity(opacity: 0.4, child: _buildRow(context))
                      : const SizedBox.shrink(),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Anchors the floating drag feedback at the source row's original
  /// top-left, so the lifted row appears in the same position it
  /// occupied at rest (mirroring `ReorderableListView`'s lift effect)
  /// rather than jumping under the small handle that initiated the drag.
  Offset _sourceTopLeftAnchor(
    Draggable<Object> _,
    BuildContext context,
    Offset position,
  ) {
    final sourceCtx = _sourceKey.currentContext;
    final box = sourceCtx?.findRenderObject() as RenderBox?;
    if (box == null) {
      return Offset.zero;
    }
    return position - box.localToGlobal(Offset.zero);
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
