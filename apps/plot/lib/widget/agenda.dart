import 'package:flutter_bloc/flutter_bloc.dart';
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
    this.thread,
    this.focusNode,
    this.text,
    this.scheduleAt,
    super.key,
  });

  final Priority? priorityContext;
  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final Thread? thread;
  final FocusNode? focusNode;
  final String? text;
  final DateTime? scheduleAt;

  @override
  Widget build(BuildContext context) {
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

      Widget result = Padding(
        padding: EdgeInsets.symmetric(vertical: verticalMargin),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: context.theme.spacing.xs),
          child: child,
        ),
      );

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
