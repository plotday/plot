import 'dart:async';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';

class AgendaHeader extends StatefulWidget {
  const AgendaHeader({
    this.priority,
    this.priorityContext,
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.activity,
    this.focusNode,
    this.text,
    this.scheduleAt,
    this.followsHeader = false,
    super.key,
  });

  final Priority? priority;
  final Priority? priorityContext;
  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final Activity? activity;
  final FocusNode? focusNode;
  final String? text;
  final DateTime? scheduleAt;
  final bool followsHeader;

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
    final now = DateTime.now();
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

  Widget _buildDurationContent(
    BuildContext context, {
    required String? durationText,
    required Duration? elapsedDuration,
    required Duration? remainingDuration,
  }) {
    // If we have elapsed or remaining durations, show with icons
    if (elapsedDuration != null || remainingDuration != null) {
      final color = widget.priority != null
          ? context.colour.colours.fromTheme(widget.priority!.displayColor)
          : context.theme.colors.mutedForeground;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (elapsedDuration != null) ...[
            Text(
              elapsedDuration.format(),
              style: TextStyle(
                color: color,
                fontSize: context.theme.typography.sm.fontSize,
              ),
            ),
            SizedBox(width: 2),
            FaIcon(
              PlotIcon.up,
              size: context.theme.typography.sm.fontSize,
              color: color,
            ),
            SizedBox(width: 6),
          ],
          if (remainingDuration != null) ...[
            Text(
              remainingDuration.format(),
              style: TextStyle(
                color: color,
                fontSize: context.theme.typography.sm.fontSize,
              ),
            ),
            SizedBox(width: 2),
            FaIcon(
              PlotIcon.down,
              size: context.theme.typography.sm.fontSize,
              color: color,
            ),
          ],
        ],
      );
    } else if (durationText != null) {
      // Show normal duration text
      return Text(
        durationText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: widget.now && widget.priority != null
              ? context.colour.colours.fromTheme(widget.priority!.displayColor)
              : context.theme.colors.mutedForeground,
          fontSize: context.theme.typography.sm.fontSize,
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Determine what to show in the center
    String? centerText = widget.text;
    if (centerText == null) {
      if (widget.dateTimeRange != null) {
        // Show time from DateTimeRange
        final timeOfDay = widget.dateTimeRange!.start?.toTimeOfDay();
        if (timeOfDay != null && timeOfDay.isMidnight != true) {
          centerText = timeOfDay.format(context);
        }
      } else if (widget.date != null) {
        // Show date
        centerText = widget.date!.format(format: 'EEEE, MMMM d, yyyy');
      }
    }

    // Determine if this is the last gap of the day (until midnight)
    bool isLastGapOfDay = false;
    if (widget.dateTimeRange != null &&
        widget.activity == null && // It's a gap, not a scheduled event
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
        final now = DateTime.now();
        final isGap = widget.activity == null;

        // Only show elapsed for events (not gaps)
        if (widget.dateTimeRange!.start != null && !isGap) {
          final elapsed = now.difference(widget.dateTimeRange!.start!);
          // Only show elapsed if at least 1 minute has passed (round down)
          if (elapsed.inMinutes >= 1) {
            elapsedDuration = Duration(minutes: elapsed.inMinutes);
          }
        }
        if (widget.dateTimeRange!.end != null) {
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

    final textColor = widget.now
        ? (widget.priority != null
              ? context.colour.colours.fromTheme(widget.priority!.displayColor)
              : widget.priorityContext != null
              ? context.colour.colours.fromTheme(
                  widget.priorityContext!.displayColor,
                )
              : context.theme.colors.mutedForeground)
        : context.theme.colors.mutedForeground;

    // Determine which command to use
    CommandWrapper? command;

    // Check if this header represents a past time
    final isPast =
        widget.date != null && widget.date!.isBefore(Date.today()) ||
        widget.dateTimeRange?.end != null &&
            widget.dateTimeRange!.end!.isBefore(DateTime.now());

    // Calculate duration: use gap duration if <1h, otherwise default to 1h
    final duration =
        widget.dateTimeRange?.duration != null &&
            widget.dateTimeRange!.duration! < const Duration(hours: 1)
        ? widget.dateTimeRange!.duration!
        : const Duration(hours: 1);

    // For headers with scheduleAt (not in the past)
    if (!isPast &&
        (widget.scheduleAt != null || widget.activity?.type == .event)) {
      // If this header has an associated event activity, use RescheduleEvent
      if (widget.activity != null &&
          widget.activity!.type == ActivityType.event) {
        command = CommandWrapper(
          RescheduleEvent(widget.activity!, showPrioritySelector: true),
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

    return Padding(
      padding: EdgeInsets.only(
        top: widget.followsHeader
            ? 0.0
            : (widget.date != null ? 32.0 : 16.0),
      ),
      child: ListTile(
        command: command,
        focusNode: widget.focusNode,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        bodyBuilder: (context, isHighlighted) {
          // Calculate background color based on date and highlighted state
          // When highlighted, composite the semi-transparent highlight color over
          // the background to create a solid color that blocks the line
          // Always provide a background when there's a date line to cover it
          final backgroundColor = widget.date != null
              ? (isHighlighted
                    ? Color.alphaBlend(
                        context.theme.plotColors.highlight,
                        context.theme.colors.background,
                      )
                    : context.theme.colors.background)
              : null;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8.0,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  // Calculate text height for consistent sizing
                  final double textHeight = (TextPainter(
                    text: TextSpan(
                      text: "A",
                      style: TextStyle(
                        fontSize: context.theme.typography.sm.fontSize,
                      ),
                    ),
                    maxLines: 1,
                    textDirection: TextDirection.ltr,
                  )..layout()).height;

                  // Determine which elements are present
                  final hasLeft =
                      widget.priority != null && widget.date == null;
                  final hasCenter = centerText != null;
                  final hasRight =
                      durationText != null ||
                      elapsedDuration != null ||
                      remainingDuration != null;
                  final elementCount = [
                    hasLeft,
                    hasCenter,
                    hasRight,
                  ].where((e) => e).length;

                  // If only one element is present, use full width
                  if (elementCount == 1) {
                    Widget content;
                    Alignment alignment;
                    EdgeInsets? padding;

                    if (hasLeft) {
                      // Full width priority label, left-aligned
                      content = PriorityLabel(
                        priority: widget.priority,
                        context: widget.priorityContext,
                        fontSize: context.theme.typography.sm.fontSize,
                      );
                      alignment = Alignment.centerLeft;
                      padding = widget.date != null
                          ? const EdgeInsets.only(right: 8)
                          : null;
                    } else if (hasCenter) {
                      // Full width date/time, centered
                      content = Text(
                        centerText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: context.theme.typography.sm.fontSize,
                        ),
                      );
                      alignment = Alignment.center;
                      padding = widget.date != null
                          ? const EdgeInsets.symmetric(horizontal: 8)
                          : null;
                    } else {
                      // Full width duration, right-aligned
                      content = _buildDurationContent(
                        context,
                        durationText: durationText,
                        elapsedDuration: elapsedDuration,
                        remainingDuration: remainingDuration,
                      );
                      alignment = Alignment.centerRight;
                      padding = widget.date != null
                          ? const EdgeInsets.only(left: 8)
                          : null;
                    }

                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Background: Full-width "now" line
                        if (widget.date != null)
                          Container(
                            height: 1,
                            decoration: BoxDecoration(
                              color: widget.now
                                  ? (widget.priority != null
                                        ? context.colour.colours.fromTheme(
                                            widget.priority!.displayColor,
                                          )
                                        : widget.priorityContext != null
                                        ? context.colour.colours.fromTheme(
                                            widget
                                                .priorityContext!
                                                .displayColor,
                                          )
                                        : context.theme.colors.mutedForeground)
                                  : context.theme.colors.border,
                            ),
                          ),
                        // Foreground: Single element with full width
                        Align(
                          alignment: alignment,
                          child: Container(
                            decoration: backgroundColor != null
                                ? BoxDecoration(color: backgroundColor)
                                : null,
                            padding: padding,
                            child: content,
                          ),
                        ),
                      ],
                    );
                  }

                  // Multiple elements: use 1:2:1 flex ratio
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Background: Full-width "now" line
                      if (widget.date != null)
                        Container(
                          height: 1,
                          decoration: BoxDecoration(
                            color: widget.now
                                ? (widget.priority != null
                                      ? context.colour.colours.fromTheme(
                                          widget.priority!.displayColor,
                                        )
                                      : widget.priorityContext != null
                                      ? context.colour.colours.fromTheme(
                                          widget.priorityContext!.displayColor,
                                        )
                                      : context.theme.colors.mutedForeground)
                                : context.theme.colors.border,
                          ),
                        ),
                      // Foreground: 3-column layout
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // LEFT: Priority label (1 flex unit)
                          Flexible(
                            flex: 1,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: hasLeft
                                  ? Container(
                                      decoration: backgroundColor != null
                                          ? BoxDecoration(
                                              color: backgroundColor,
                                            )
                                          : null,
                                      padding: widget.date != null
                                          ? const EdgeInsets.only(right: 8)
                                          : null,
                                      child: PriorityLabel(
                                        priority: widget.priority,
                                        context: widget.priorityContext,
                                        fontSize: context
                                            .theme
                                            .typography
                                            .sm
                                            .fontSize,
                                      ),
                                    )
                                  : SizedBox(height: textHeight),
                            ),
                          ),
                          // CENTER: Date/time (2 flex units for true centering)
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: hasCenter
                                  ? Container(
                                      decoration: backgroundColor != null
                                          ? BoxDecoration(
                                              color: backgroundColor,
                                            )
                                          : null,
                                      padding: widget.date != null
                                          ? const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            )
                                          : null,
                                      child: Text(
                                        centerText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: textColor,
                                          fontSize: context
                                              .theme
                                              .typography
                                              .sm
                                              .fontSize,
                                        ),
                                      ),
                                    )
                                  : SizedBox(height: textHeight),
                            ),
                          ),
                          // RIGHT: Duration (1 flex unit)
                          Flexible(
                            flex: 1,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: hasRight
                                  ? Container(
                                      decoration: backgroundColor != null
                                          ? BoxDecoration(
                                              color: backgroundColor,
                                            )
                                          : null,
                                      padding: widget.date != null
                                          ? const EdgeInsets.only(left: 8)
                                          : null,
                                      child: _buildDurationContent(
                                        context,
                                        durationText: durationText,
                                        elapsedDuration: elapsedDuration,
                                        remainingDuration: remainingDuration,
                                      ),
                                    )
                                  : SizedBox(height: textHeight),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
