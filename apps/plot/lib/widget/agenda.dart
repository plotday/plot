import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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
  final fontSize = context.theme.typography.xs.fontSize;
  final textWidth = (TextPainter(
    text: TextSpan(
      text: maxTimeText,
      style: TextStyle(fontSize: fontSize),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout()).width;
  final pad = isWide ? context.theme.spacing.sm : context.theme.spacing.sm;
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
            ? ' ${date!.format(format: 'MMMM')}'
            : ' ${date!.format(format: 'MMMM yyyy')}';
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

    // Use xs font size for event headers and gap headers to match thread timing labels
    final fontSize = (thread != null && !now) || isGapHeader
        ? context.theme.typography.xs.fontSize
        : context.theme.typography.sm.fontSize;

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
      // Match PriorityPage section headers: sm font, md+xs (12px) vertical
      // padding so the agenda date header reads at the same weight as the
      // activity-feed "Today"/"New"/"Scheduled"/"Done" markers.
      final dateFontSize = context.theme.typography.sm.fontSize;
      final mutedStyle = TextStyle(
        color: context.theme.plotColors.veryMuted,
        fontSize: dateFontSize,
      );

      final Widget child;
      if (dateCenterLeft != null) {
        // Full date: [day-of-week] [day] [month]
        final spacing = context.theme.spacing.md;
        child = Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  dateCenterLeft,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mutedStyle,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing),
              child: Text(
                dateCenterRight!,
                style: TextStyle(
                  color: context.theme.colors.mutedForeground,
                  fontSize: dateFontSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
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
          ],
        );
      } else {
        // Relative date label ("Yesterday", "2 days ago", etc.)
        child = Center(child: Text(centerText!, style: mutedStyle));
      }

      final verticalPad =
          context.theme.spacing.md + context.theme.spacing.xs;
      return Container(
        color: headerBg,
        padding: EdgeInsets.symmetric(vertical: verticalPad),
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
          padding: EdgeInsets.symmetric(
            vertical: context.theme.spacing.md + context.theme.spacing.xs,
          ),
          child: child,
        );
      } else {
        result = Container(
          color: isGapHeader ? context.colour.headerBackground : null,
          padding: EdgeInsets.symmetric(vertical: context.theme.spacing.xs),
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
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.xs),
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
/// need a per-minute timer to refresh elapsed/remaining counters and
/// because hover state controls the drag-grip affordance.
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

  Priority get priority => block.priority;

  @override
  State<_BlockHeader> createState() => _BlockHeaderState();
}

class _BlockHeaderState extends State<_BlockHeader> {
  Timer? _tick;
  bool _hover = false;
  BlockDragController? _dragController;

  /// True when this block header is itself a drag source (a non-event
  /// block with a known parent block id). Outside-priority gating is
  /// no longer relevant in the universal agenda — every priority's
  /// blocks are equally first-class.
  bool get _isDraggable =>
      widget.parentBlockId != null && widget.thread == null;

  /// True while THIS block is being dragged — the source row collapses
  /// to zero height while a feedback widget floats under the pointer.
  bool get _isBeingDragged =>
      _dragController?.draggingBlockId != null &&
      _dragController!.draggingBlockId == widget.parentBlockId;

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

  Widget _buildRow(BuildContext context, {Widget? grip}) {
    final block = widget.block;
    final priority = block.priority;
    final dateTimeRange = widget.dateTimeRange;
    final thread = widget.thread;

    final fg = context.colour.colours.fromTheme(priority.displayColor);
    final mutedFg = context.colour.colours.fromTheme(
      priority.displayColor,
      muted: true,
    );
    final bg = context.colour.colours.backgroundFromTheme(
      priority.displayColor,
    );
    final spacing = context.theme.spacing;
    final smSize = context.theme.typography.sm.fontSize ?? 14;
    final xsSize = context.theme.typography.xs.fontSize ?? 12;

    final hasTime = dateTimeRange != null;
    final timeOfDay = dateTimeRange?.start?.toTimeOfDay();
    final timeText = hasTime && timeOfDay != null && !timeOfDay.isMidnight
        ? (context.isMultiPanel
              ? timeOfDay.formatShort(context)
              : timeOfDay.formatNarrow(context))
        : null;

    final summary = block.summaryLine;
    final hasUnread = block.hasUnread;

    // Right meta children (RSVP + duration / active timing).
    final rightChildren = <Widget>[];
    if (thread != null && thread.hasOtherAttendees) {
      rightChildren.add(RsvpSummary(activity: thread));
      rightChildren.add(SizedBox(width: spacing.sm));
      rightChildren.add(
        Text(
          '·',
          style: TextStyle(color: mutedFg, fontSize: xsSize, height: 1),
        ),
      );
      rightChildren.add(SizedBox(width: spacing.sm));
    }

    if (widget.now && thread?.at?.start != null) {
      // Active-timing display: ↑Xm elapsed in fg, /Ym remaining in muted.
      final currentTime = Time.now();
      final start = thread!.at!.start!;
      final end = thread.at!.end;
      final elapsed = currentTime.difference(start).inMinutes;
      if (elapsed >= 1) {
        rightChildren.add(
          Text(
            '↑${Duration(minutes: elapsed).format()}',
            style: TextStyle(color: fg, fontSize: xsSize, height: 1),
          ),
        );
      }
      if (end != null && end.isAfter(currentTime)) {
        final remaining = (end.difference(currentTime).inSeconds / 60).ceil();
        rightChildren.add(SizedBox(width: spacing.xs));
        rightChildren.add(
          Text(
            '/ ${Duration(minutes: remaining).format()}',
            style: TextStyle(color: mutedFg, fontSize: xsSize, height: 1),
          ),
        );
      }
    } else {
      // Static duration with hover stepper / touch modal trigger.
      rightChildren.add(
        DurationControl(
          value: dateTimeRange?.duration,
          onChanged: thread == null
              ? null
              : (newDur) => SetThreadDuration(thread, newDur).run(context),
          foreground: fg,
        ),
      );
    }

    final timeColWidth = agendaLeadingWidth(context);

    // Unread dot color: priority accent at reduced alpha to mirror
    // [PriorityNotification]'s _DotPainter treatment.
    final unreadColor = fg.withValues(alpha: 0.7);

    return Container(
      color: bg,
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (grip != null) grip,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeColWidth,
                child: Padding(
                  padding: EdgeInsets.only(right: spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (timeText != null)
                        Text(
                          timeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg,
                            fontSize: xsSize,
                            height: 1,
                          ),
                        ),
                      if (hasUnread) ...[
                        SizedBox(height: 4),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: unreadColor,
                            shape: BoxShape.circle,
                          ),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        if (thread != null) ...[
                          Flexible(
                            child: Text(
                              thread.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg,
                                fontSize: smSize,
                                fontWeight: FontWeight.w600,
                                height: 1,
                              ),
                            ),
                          ),
                          SizedBox(width: spacing.sm),
                        ],
                        Flexible(
                          child: PriorityLabel(
                            priority: priority,
                            color: fg,
                            mutedAncestorColor: mutedFg,
                            fontSize: thread != null ? xsSize : smSize,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      SizedBox(height: spacing.xs),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedFg,
                          fontSize: xsSize,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              ...rightChildren,
              SizedBox(width: spacing.lg),
            ],
          ),
        ],
      ),
    );
  }

  /// Builds the floating-feedback widget shown under the pointer during
  /// a block drag. Sized to the source row's actual rendered width so
  /// the feedback keeps the row's shape (rather than expanding to the
  /// full viewport).
  Widget _buildFeedback(BuildContext context, {required double rowWidth}) {
    return SizedBox(width: rowWidth, child: _buildRow(context));
  }

  /// Hover-revealed grip placed inline immediately after the priority
  /// breadcrumb. Purely a visual affordance — the actual drag gesture
  /// lives on the surrounding draggable so any spot on the header is a
  /// drag handle.
  Widget _buildGrip(BuildContext context) {
    final fg = context.colour.colours.fromTheme(
      widget.priority.displayColor,
      muted: true,
    );
    final iconSize = context.theme.typography.xs.fontSize ?? 12;
    final visible = _hover && !_isBeingDragged;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 100),
      child: IgnorePointer(
        ignoring: true,
        child: FaIcon(
          FontAwesomeIcons.gripDotsVertical,
          size: iconSize,
          color: fg,
        ),
      ),
    );
  }

  /// Wraps [child] in a tap handler that navigates to this block's
  /// priority page. Applies uniformly to priority, gap-with-threads,
  /// and event block headers — clicking the header always opens the
  /// priority's full page (the dedicated event row beneath the header
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => OpenPriority(widget.priority).run(context),
      child: child,
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

    // Source row at rest (and as the layout slot the Draggable measures
    // for `childDragAnchorStrategy`). The [GlobalKey] lets the controller
    // read its natural bounds at drag start before `childWhenDragging`
    // shrinks this slot.
    final source = KeyedSubtree(
      key: _sourceKey,
      child: _buildRow(context, grip: _buildGrip(context)),
    );

    // While the drag is active the source's slot in the agenda flips
    // between "dimmed in place" (cursor in the source's deadzone) and
    // "collapsed to zero" (cursor over a real drop slot — the source's
    // space has logically moved to that slot, which expands to match).
    // [AnimatedSize] smooths the transition so the swap reads as a
    // gap-following animation, similar to `SliverReorderableList`.
    final draggingChild = ListenableBuilder(
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
      MouseRegion(
        onEnter: (_) {
          if (_hover) return;
          setState(() => _hover = true);
        },
        onExit: (_) {
          if (!_hover) return;
          setState(() => _hover = false);
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final rowWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.of(context).size.width;
            // Desktop (mouse) → immediate Draggable so any click-and-drag on
            // the header starts a drag. Mobile → LongPressDraggable so a
            // short tap or scroll doesn't accidentally pick up the block.
            if (hasPhysicalKeyboard()) {
              return Draggable<BlockDragPayload>(
                data: payload,
                feedback: _buildFeedback(context, rowWidth: rowWidth),
                childWhenDragging: draggingChild,
                onDragStarted: () => _onDragStarted(payload),
                onDragUpdate: _onDragUpdate,
                onDragEnd: _onDragEndedWith,
                onDraggableCanceled: (_, _) => _onDragEnded(),
                child: source,
              );
            }
            return LongPressDraggable<BlockDragPayload>(
              data: payload,
              delay: const Duration(milliseconds: 300),
              feedback: _buildFeedback(context, rowWidth: rowWidth),
              childWhenDragging: draggingChild,
              onDragStarted: () => _onDragStarted(payload),
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEndedWith,
              onDraggableCanceled: (_, _) => _onDragEnded(),
              child: source,
            );
          },
        ),
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
