import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';

/// Width of the leading column: widest possible time string + horizontal padding.
/// Used by both [AgendaHeader] gap rows and [ThreadWidget] leading areas.
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

class AgendaHeader extends StatelessWidget {
  const AgendaHeader({
    this.priorityContext,
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.isNext = false,
    this.thread,
    this.focusNode,
    this.text,
    this.scheduleAt,
    this.blockPriority,
    super.key,
  });

  final Priority? priorityContext;
  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final bool isNext;
  final Thread? thread;
  final FocusNode? focusNode;
  final String? text;
  final DateTime? scheduleAt;

  /// When set, render a combined block header carrying this priority's
  /// breadcrumb plus a priority-tinted background.
  final Priority? blockPriority;

  @override
  Widget build(BuildContext context) {
    if (blockPriority != null) {
      return _BlockHeader(
        priority: blockPriority!,
        priorityContext: priorityContext,
        dateTimeRange: dateTimeRange,
        thread: thread,
        now: now,
        isNext: isNext,
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

    // Use priorityContext color when available, otherwise muted.
    final nowColor = priorityContext != null
        ? context.colour.colours.fromTheme(priorityContext!.displayColor)
        : context.theme.colors.mutedForeground;

    final textColor = now ? nowColor : context.theme.colors.mutedForeground;

    // Detect gap headers (time gaps between scheduled events).
    // The now flag indicates the current time position but doesn't change
    // that this is a gap header — it only affects styling (accent color).
    final isGapHeader =
        thread == null && dateTimeRange != null && date == null;

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
      final dateFontSize = dateCenterLeft == null
          ? context.theme.typography.xs.fontSize
          : context.theme.typography.md.fontSize;
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
                  color: textColor,
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

      final verticalPad = dateCenterLeft != null
          ? context.theme.spacing.lg
          : context.theme.spacing.sm;
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

      // Empty gap headers (no priority) share the date-header background
      // so they read as a neutral time marker rather than a priority block.
      Widget result = Container(
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
/// need a per-minute timer to refresh elapsed/remaining counters.
class _BlockHeader extends StatefulWidget {
  const _BlockHeader({
    required this.priority,
    required this.priorityContext,
    required this.dateTimeRange,
    required this.thread,
    required this.now,
    required this.isNext,
  });

  final Priority priority;
  final Priority? priorityContext;
  final DateTimeRange? dateTimeRange;
  final Thread? thread;
  final bool now;
  final bool isNext;

  @override
  State<_BlockHeader> createState() => _BlockHeaderState();
}

class _BlockHeaderState extends State<_BlockHeader> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
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
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final priority = widget.priority;
    final dateTimeRange = widget.dateTimeRange;
    final thread = widget.thread;

    final fg = context.colour.colours.fromTheme(priority.displayColor);
    final bg = context.colour.colours.backgroundFromTheme(priority.displayColor);
    final fontSize = context.theme.typography.xs.fontSize;
    final iconSize = fontSize ?? 12;
    final spacing = context.theme.spacing;
    final currentTime = Time.now();

    final hasTime = dateTimeRange != null;
    final timeOfDay = dateTimeRange?.start?.toTimeOfDay();
    final timeText = hasTime && timeOfDay != null && !timeOfDay.isMidnight
        ? (context.isMultiPanel
              ? timeOfDay.formatShort(context)
              : timeOfDay.formatNarrow(context))
        : null;
    final hasDuration =
        dateTimeRange?.duration != null &&
        dateTimeRange!.duration!.inSeconds > 0;
    final isLastGapOfDay =
        hasTime &&
        thread == null &&
        dateTimeRange.end?.hour == 0 &&
        dateTimeRange.end?.minute == 0 &&
        dateTimeRange.end?.second == 0;

    // Build right-side metadata children for event blocks.
    final rightParts = <Widget>[];
    if (thread != null && thread.hasOtherAttendees) {
      rightParts.add(RsvpSummary(activity: thread));
    }
    if (widget.now && thread != null) {
      // In-progress: elapsed ↑ since start, remaining ↓ until end.
      final start = thread.at?.start;
      final end = thread.at?.end;
      if (start != null && currentTime.difference(start).inMinutes >= 1) {
        rightParts.add(_metaPair(
          text: Duration(
            minutes: currentTime.difference(start).inMinutes,
          ).format(),
          icon: PlotIcon.up,
          color: fg,
          iconSize: iconSize,
        ));
      }
      if (end != null && end.isAfter(currentTime)) {
        rightParts.add(_metaPair(
          text: Duration(
            minutes: (end.difference(currentTime).inSeconds / 60).ceil(),
          ).format(),
          icon: PlotIcon.down,
          color: fg,
          iconSize: iconSize,
        ));
      }
    } else if (widget.isNext &&
        thread?.at?.start != null &&
        thread!.at!.start!.toDate() == Date.today()) {
      rightParts.add(Text(
        'In ${Duration(minutes: (thread.at!.start!.difference(currentTime).inSeconds / 60).ceil()).format()}',
      ));
    }
    if (hasDuration && !isLastGapOfDay && !widget.now) {
      rightParts.add(Text(dateTimeRange.duration!.format()));
    }

    final timeColWidth = agendaLeadingWidth(context);

    return Container(
      color: bg,
      padding: EdgeInsets.symmetric(vertical: spacing.sm),
      child: DefaultTextStyle(
        style: TextStyle(color: fg, fontSize: fontSize, height: 1),
        child: Row(
          children: [
            SizedBox(
              width: timeColWidth,
              child: Padding(
                padding: EdgeInsets.only(right: spacing.sm),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: timeText == null
                      ? const SizedBox.shrink()
                      : Text(
                          timeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
              ),
            ),
            Expanded(
              child: PriorityLabel(
                priority: priority,
                context: widget.priorityContext,
                color: fg,
                fontSize: fontSize,
                height: 1,
              ),
            ),
            for (var i = 0; i < rightParts.length; i++) ...[
              if (i > 0) SizedBox(width: spacing.sm),
              rightParts[i],
            ],
            if (rightParts.isNotEmpty) SizedBox(width: spacing.lg),
          ],
        ),
      ),
    );
  }

  static Widget _metaPair({
    required String text,
    required IconData icon,
    required Color color,
    required double iconSize,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        SizedBox(width: 4),
        FaIcon(icon, size: iconSize, color: color),
      ],
    );
  }
}
