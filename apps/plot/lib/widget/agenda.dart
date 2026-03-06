import 'dart:async';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/widget/widget.dart';

class AgendaHeader extends StatefulWidget {
  const AgendaHeader({
    this.priority,
    this.priorityContext,
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.thread,
    this.focusNode,
    this.text,
    this.scheduleAt,
    this.compact = false,
    super.key,
  });

  final Priority? priority;
  final Priority? priorityContext;
  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final Thread? thread;
  final FocusNode? focusNode;
  final String? text;
  final DateTime? scheduleAt;
  final bool compact;

  @override
  State<AgendaHeader> createState() => _AgendaHeaderState();
}

class _AgendaHeaderState extends State<AgendaHeader> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimerIfNeeded();
  }

  @override
  void didUpdateWidget(AgendaHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Restart timer if now state changed
    if (oldWidget.now != widget.now) {
      _timer?.cancel();
      _timer = null;
      _startTimerIfNeeded();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimerIfNeeded() {
    if (!widget.now) return;

    // Calculate seconds until next minute boundary
    final now = Time.now();
    final secondsUntilNextMinute = 60 - now.second;

    // Start timer to next minute boundary
    _timer = Timer(Duration(seconds: secondsUntilNextMinute), () {
      if (mounted) {
        setState(() {});
        // Start periodic timer for subsequent minutes
        _timer = Timer.periodic(const Duration(minutes: 1), (_) {
          if (mounted) {
            setState(() {});
          }
        });
      }
    });
  }

  /// Renders time text centered on the AM/PM boundary (12h) or plain centered (24h).
  Widget _buildCenteredTime({
    required String? timeCenterLeft,
    required String? timeCenterRight,
    required String? centerText,
    required Color textColor,
    required double? fontSize,
    required Color backgroundColor,
    required double spacing,
    required double textHeight,
  }) {
    if (timeCenterLeft != null) {
      final textStyle = TextStyle(color: textColor, fontSize: fontSize);
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                color: backgroundColor,
                padding: EdgeInsets.only(left: spacing),
                child: Text(
                  timeCenterLeft,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                color: backgroundColor,
                padding: EdgeInsets.only(right: spacing),
                child: Text(
                  timeCenterRight!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ),
          ),
        ],
      );
    } else if (centerText != null) {
      return Center(
        child: Container(
          color: backgroundColor,
          padding: EdgeInsets.symmetric(horizontal: spacing),
          child: Text(
            centerText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor, fontSize: fontSize),
          ),
        ),
      );
    }
    return Center(child: SizedBox(height: textHeight));
  }

  @override
  Widget build(BuildContext context) {
    // Determine what to show in the center
    String? centerText = widget.text;
    // Split date into two parts for center-on-month alignment
    String? dateCenterLeft;
    String? dateMonth;
    String? dateCenterRight;
    if (centerText == null) {
      if (widget.now) {
        centerText = 'Now';
      } else if (widget.dateTimeRange != null) {
        // Show time from DateTimeRange
        final timeOfDay = widget.dateTimeRange!.start?.toTimeOfDay();
        if (timeOfDay != null && timeOfDay.isMidnight != true) {
          centerText = timeOfDay.formatShort(context);
        }
      } else if (widget.date != null) {
        // Show date split into day-of-week and month+day for centered layout
        dateCenterLeft = widget.date!.format(format: 'EEEE');
        dateCenterRight = widget.date!.format(format: 'd');
        dateMonth = widget.date!.year == Date.today().year
            ? ' ${widget.date!.format(format: 'MMMM')}'
            : ' ${widget.date!.format(format: 'MMMM, yyyy')}';
      }
    }

    // Split time text at AM/PM boundary for center alignment
    String? timeCenterLeft;
    String? timeCenterRight;
    if (centerText != null) {
      final amPmMatch = RegExp(r'[ap]m$').firstMatch(centerText);
      if (amPmMatch != null) {
        timeCenterLeft = centerText.substring(0, amPmMatch.start);
        timeCenterRight = centerText.substring(amPmMatch.start);
      }
    }

    // Determine if this is the last gap of the day (until midnight)
    bool isLastGapOfDay = false;
    if (widget.dateTimeRange != null &&
        widget.thread == null && // It's a gap, not a scheduled event
        widget.dateTimeRange!.end != null) {
      // Check if the end time is at midnight (start of next day)
      final endTime = widget.dateTimeRange!.end!;
      isLastGapOfDay =
          endTime.hour == 0 && endTime.minute == 0 && endTime.second == 0;
    }

    // Determine duration text or elapsed/remaining times
    String? durationText;
    Duration? elapsedDuration;
    Duration? remainingDuration;

    if (widget.dateTimeRange != null &&
        widget.dateTimeRange!.duration?.inSeconds != null &&
        widget.dateTimeRange!.duration!.inSeconds > 0 &&
        !isLastGapOfDay) {
      if (widget.now) {
        // Calculate elapsed and remaining times
        final now = Time.now();
        final isGap = widget.thread == null;

        // Only show elapsed for events (not gaps)
        if (widget.dateTimeRange!.start != null && !isGap) {
          final elapsed = now.difference(widget.dateTimeRange!.start!);
          // Only show elapsed if at least 1 minute has passed (round down)
          if (elapsed.inMinutes >= 1) {
            elapsedDuration = Duration(minutes: elapsed.inMinutes);
          }
        }
        if (widget.dateTimeRange!.end != null &&
            widget.dateTimeRange!.end!.toDate() == now.toDate()) {
          final remaining = widget.dateTimeRange!.end!.difference(now);
          // Always round up remaining time
          final remainingMinutes = (remaining.inSeconds / 60).ceil();
          if (remainingMinutes > 0) {
            remainingDuration = Duration(minutes: remainingMinutes);
          }
        }
      } else {
        // Show normal duration text when not "now"
        durationText = widget.dateTimeRange!.duration!.format();
      }
    }

    // When a scheduled event is in progress, use its priority color;
    // otherwise fall back to priorityContext color.
    final nowColor = widget.thread != null && widget.priority != null
        ? context.colour.colours.fromTheme(widget.priority!.displayColor)
        : widget.priorityContext != null
        ? context.colour.colours.fromTheme(widget.priorityContext!.displayColor)
        : widget.priority != null
        ? context.colour.colours.fromTheme(widget.priority!.displayColor)
        : context.theme.colors.mutedForeground;

    final textColor = widget.now
        ? nowColor
        : context.theme.colors.mutedForeground;

    // Detect gap headers (time gaps between scheduled events)
    final isGapHeader =
        widget.thread == null &&
        widget.dateTimeRange != null &&
        widget.date == null &&
        !widget.now;

    // Use xs font size for event headers and gap headers to match thread timing labels
    final fontSize = (widget.thread != null && !widget.now) || isGapHeader
        ? context.theme.typography.xs.fontSize
        : context.theme.typography.sm.fontSize;

    // Determine which command to use
    CommandWrapper? command;

    // Check if this header represents a past time
    final isPast =
        widget.date != null && widget.date!.isBefore(Date.today()) ||
        widget.dateTimeRange?.end != null &&
            widget.dateTimeRange!.end!.isBefore(Time.now());

    // Calculate duration: use gap duration if <1h, otherwise default to 1h
    final duration =
        widget.dateTimeRange?.duration != null &&
            widget.dateTimeRange!.duration! < const Duration(hours: 1)
        ? widget.dateTimeRange!.duration!
        : const Duration(hours: 1);

    // For headers with scheduleAt (not in the past)
    if (!isPast && (widget.scheduleAt != null || widget.thread?.at != null)) {
      // If this header has an associated event activity, use RescheduleEvent
      if (widget.thread != null && widget.thread!.at != null) {
        command = CommandWrapper(
          RescheduleEvent(widget.thread!, showPrioritySelector: true),
          icon: Value(null),
        );
      } else if (widget.priority != null) {
        // Otherwise, create a new event (only if priority is set)
        command = CommandWrapper(
          NewEvent(
            priority: widget.priority!,
            startTime: widget.scheduleAt!,
            duration: duration,
          ),
          icon: Value(null),
        );
      }
    } else if (widget.priority != null &&
        widget.priority!.id != widget.priorityContext?.id) {
      // Priority header: Open the priority
      command = CommandWrapper(
        OpenPriority.byId(widget.priority!.id),
        icon: Value(null),
      );
    }

    final verticalMargin = isGapHeader
        ? 0.0
        : widget.date != null
        ? context.theme.spacing.xl
        : (widget.compact
              ? context.theme.spacing.xs
              : context.theme.spacing.md);

    // Date headers: simple container with darkened background, no ListTile needed
    if (widget.date != null) {
      final headerBg = context.colour.headerBackground;
      final dateFontSize = dateCenterLeft == null
          ? context.theme.typography.sm.fontSize
          : context.theme.typography.base.fontSize;
      final veryMuted = context.theme.plotColors.veryMuted;
      final mutedStyle = TextStyle(color: veryMuted, fontSize: dateFontSize);

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
                style: TextStyle(color: textColor, fontSize: dateFontSize),
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
          ? context.theme.spacing.xl
          : context.theme.spacing.md;
      return Container(
        color: headerBg,
        padding: EdgeInsets.symmetric(vertical: verticalPad),
        child: child,
      );
    }

    Widget tile = ListTile(
      command: command,
      focusNode: widget.focusNode,
      noHoverHighlight: isGapHeader || widget.now,
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.xs,
      ),
      bodyBuilder: (context, isHighlighted) {
        final backgroundColor = isHighlighted && !isGapHeader && !widget.now
            ? Color.alphaBlend(
                context.theme.plotColors.highlight,
                context.theme.colors.background,
              )
            : context.theme.colors.background;

        return LayoutBuilder(
              builder: (context, constraints) {
                final double textHeight = (TextPainter(
                  text: TextSpan(
                    text: "A",
                    style: TextStyle(fontSize: fontSize),
                  ),
                  maxLines: 1,
                  textDirection: TextDirection.ltr,
                )..layout()).height;

                final spacing = context.theme.spacing.md;

                // Gap/time headers: centered time with optional duration on right
                if (isGapHeader || (!widget.now && centerText != null)) {
                  final veryMuted = context.theme.plotColors.veryMuted;
                  final contentColor = isGapHeader ? veryMuted : textColor;
                  final timeStyle = TextStyle(
                    color: contentColor,
                    fontSize: fontSize,
                  );

                  if (timeCenterLeft == null && centerText == null) {
                    return SizedBox(height: textHeight);
                  }

                  // Width of a single space for the AM/PM gap
                  final spaceWidth = (TextPainter(
                    text: TextSpan(
                      text: ' ',
                      style: TextStyle(fontSize: fontSize),
                    ),
                    maxLines: 1,
                    textDirection: TextDirection.ltr,
                  )..layout()).width;

                  final String leftText;
                  final String? rightText;
                  if (timeCenterLeft != null) {
                    leftText = timeCenterLeft.trimRight();
                    rightText = timeCenterRight;
                  } else {
                    leftText = centerText!;
                    rightText = null;
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: Container(
                          color: backgroundColor,
                          padding: EdgeInsets.only(left: spacing),
                          child: Text(
                            leftText,
                            style: timeStyle,
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ),
                      SizedBox(width: spaceWidth),
                      Expanded(
                        child: Container(
                          color: backgroundColor,
                          child: Row(
                            children: [
                              if (rightText != null)
                                Text(rightText, style: timeStyle),
                              const Spacer(),
                              if (durationText != null)
                                Text(
                                  durationText,
                                  style: TextStyle(
                                    color: veryMuted,
                                    fontSize: fontSize,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                }

                // Now header with elapsed/remaining: 3-column layout
                if (widget.now &&
                    (elapsedDuration != null || remainingDuration != null)) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // LEFT: Elapsed
                      Flexible(
                        flex: 2,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: elapsedDuration != null
                              ? Container(
                                  color: backgroundColor,
                                  padding: EdgeInsets.only(right: spacing),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      FaIcon(
                                        PlotIcon.up,
                                        size: fontSize,
                                        color: nowColor,
                                      ),
                                      SizedBox(
                                        width: context.theme.spacing.xs,
                                      ),
                                      Text(
                                        elapsedDuration.format(),
                                        style: TextStyle(
                                          color: nowColor,
                                          fontSize: fontSize,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : SizedBox(height: textHeight),
                        ),
                      ),
                      // CENTER: "Now" (or time text)
                      Expanded(
                        flex: 2,
                        child: _buildCenteredTime(
                          timeCenterLeft: timeCenterLeft,
                          timeCenterRight: timeCenterRight,
                          centerText: centerText,
                          textColor: textColor,
                          fontSize: fontSize,
                          backgroundColor: backgroundColor,
                          spacing: spacing,
                          textHeight: textHeight,
                        ),
                      ),
                      // RIGHT: Remaining
                      Flexible(
                        flex: 2,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: remainingDuration != null
                              ? Container(
                                  color: backgroundColor,
                                  padding: EdgeInsets.only(left: spacing),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        remainingDuration.format(),
                                        style: TextStyle(
                                          color: nowColor,
                                          fontSize: fontSize,
                                        ),
                                      ),
                                      SizedBox(
                                        width: context.theme.spacing.xs,
                                      ),
                                      FaIcon(
                                        PlotIcon.down,
                                        size: fontSize,
                                        color: nowColor,
                                      ),
                                    ],
                                  ),
                                )
                              : SizedBox(height: textHeight),
                        ),
                      ),
                    ],
                  );
                }

                // Centered text only (e.g., "Now" without elapsed/remaining)
                if (centerText != null) {
                  return _buildCenteredTime(
                    timeCenterLeft: timeCenterLeft,
                    timeCenterRight: timeCenterRight,
                    centerText: centerText,
                    textColor: textColor,
                    fontSize: fontSize,
                    backgroundColor: backgroundColor,
                    spacing: spacing,
                    textHeight: textHeight,
                  );
                }

                // Duration only: right-aligned
                if (durationText != null) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: EdgeInsets.only(left: spacing),
                      child: Text(
                        durationText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.theme.colors.mutedForeground,
                          fontSize: fontSize,
                        ),
                      ),
                    ),
                  );
                }

                return SizedBox(height: textHeight);
              },
            );
      },
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalMargin),
      child: tile,
    );
  }
}
