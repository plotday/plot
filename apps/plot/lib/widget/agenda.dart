import 'dart:async';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
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
    this.activity,
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
  final Thread? activity;
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

  Widget _buildDurationContent(
    BuildContext context, {
    required double? fontSize,
    required String? durationText,
    required Duration? elapsedDuration,
    required Duration? remainingDuration,
    required Color nowColor,
  }) {
    // If we have elapsed or remaining durations, show with icons
    if (elapsedDuration != null || remainingDuration != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (elapsedDuration != null) ...[
            Text(
              elapsedDuration.format(),
              style: TextStyle(color: nowColor, fontSize: fontSize),
            ),
            SizedBox(width: context.theme.spacing.xs),
            FaIcon(PlotIcon.up, size: fontSize, color: nowColor),
            SizedBox(width: context.theme.spacing.sm),
          ],
          if (remainingDuration != null) ...[
            Text(
              remainingDuration.format(),
              style: TextStyle(color: nowColor, fontSize: fontSize),
            ),
            SizedBox(width: context.theme.spacing.xs),
            FaIcon(PlotIcon.down, size: fontSize, color: nowColor),
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
          color: widget.now ? nowColor : context.theme.colors.mutedForeground,
          fontSize: fontSize,
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
    // Split date into two parts for center-on-month alignment
    String? dateCenterLeft;
    String? dateCenterRight;
    if (centerText == null) {
      if (widget.now) {
        centerText = 'Now';
      } else if (widget.dateTimeRange != null) {
        // Show time from DateTimeRange
        final timeOfDay = widget.dateTimeRange!.start?.toTimeOfDay();
        if (timeOfDay != null && timeOfDay.isMidnight != true) {
          centerText = timeOfDay.format(context);
        }
      } else if (widget.date != null) {
        // Show date split into day-of-week and month+day for centered layout
        dateCenterLeft = '${widget.date!.format(format: 'EEEE')}, ';
        dateCenterRight = widget.date!.year == Date.today().year
            ? widget.date!.format(format: 'MMMM d')
            : widget.date!.format(format: 'MMMM d, yyyy');
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
        final now = Time.now();
        final isGap = widget.activity == null;

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
    final nowColor = widget.activity != null && widget.priority != null
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
        widget.activity == null &&
        widget.dateTimeRange != null &&
        widget.date == null &&
        !widget.now;

    // Use xs font size for event headers and gap headers to match thread timing labels
    final fontSize = (widget.activity != null && !widget.now) || isGapHeader
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
    if (!isPast && (widget.scheduleAt != null || widget.activity?.at != null)) {
      // If this header has an associated event activity, use RescheduleEvent
      if (widget.activity != null && widget.activity!.at != null) {
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

    final verticalMargin = isGapHeader
        ? 0.0
        : widget.date != null
        ? context.theme.spacing.xl
        : (widget.compact
              ? context.theme.spacing.xs
              : context.theme.spacing.md);

    return Padding(
          padding: EdgeInsets.symmetric(vertical: verticalMargin),
          child: ListTile(
            command: command,
            focusNode: widget.focusNode,
            noHoverHighlight: isGapHeader || widget.date != null || widget.now,
            padding: EdgeInsets.symmetric(
              horizontal: context.contentPaddingH,
              vertical: context.theme.spacing.xs,
            ),
            bodyBuilder: (context, isHighlighted) {
              // Calculate background color based on date and highlighted state
              // When highlighted, composite the semi-transparent highlight color over
              // the background to create a solid color that blocks the line
              // Always provide a background when there's a date or now line to cover it
              final backgroundColor =
                  isHighlighted &&
                      widget.date == null &&
                      !isGapHeader &&
                      !widget.now
                  ? Color.alphaBlend(
                      context.theme.plotColors.highlight,
                      context.theme.colors.background,
                    )
                  : context.theme.colors.background;

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
                          style: TextStyle(fontSize: fontSize),
                        ),
                        maxLines: 1,
                        textDirection: TextDirection.ltr,
                      )..layout()).height;

                      // Determine which elements are present
                      // For now headers, elapsed goes left and remaining goes right
                      // Priority labels are handled by ThreadWidget
                      final hasLeft = widget.now && elapsedDuration != null;
                      final hasCenter =
                          centerText != null || dateCenterLeft != null;
                      final hasRight = widget.now
                          ? remainingDuration != null
                          : durationText != null ||
                                elapsedDuration != null ||
                                remainingDuration != null;
                      final elementCount = [
                        hasLeft,
                        hasCenter,
                        hasRight,
                      ].where((e) => e).length;

                      // Indent to align rule with ThreadWidget body
                      final leadingIndent =
                          context.theme.iconSizes.base +
                          7.5 +
                          context.theme.spacing.sm;

                      // Gap headers: left-aligned with dot separator
                      // (matching thread time info style)
                      if (isGapHeader) {
                        final gapColor = widget.now
                            ? nowColor
                            : context.theme.plotColors.veryMuted;

                        final gapRow = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasCenter)
                              Text(
                                centerText!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: gapColor,
                                  fontSize: fontSize,
                                ),
                              ),
                            if (hasCenter && hasRight)
                              Text(
                                ' · ',
                                style: TextStyle(
                                  color: gapColor,
                                  fontSize: fontSize,
                                ),
                              ),
                            if (hasRight)
                              widget.now
                                  ? _buildDurationContent(
                                      context,
                                      fontSize: fontSize,
                                      durationText: durationText,
                                      elapsedDuration: elapsedDuration,
                                      remainingDuration: remainingDuration,
                                      nowColor: nowColor,
                                    )
                                  : Text(
                                      durationText!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: gapColor,
                                        fontSize: fontSize,
                                      ),
                                    ),
                          ],
                        );

                        return Center(child: gapRow);
                      }

                      // If only one element is present, use full width
                      if (elementCount == 1) {
                        Widget content;
                        Alignment alignment;
                        EdgeInsets? padding;

                        if (hasCenter) {
                          if (dateCenterLeft != null) {
                            // Date header: split into two halves centered on month
                            final textStyle = TextStyle(
                              color: textColor,
                              fontSize: fontSize,
                            );
                            final spacing = context.theme.spacing.md;
                            content = Row(
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Container(
                                      color: backgroundColor,
                                      padding: EdgeInsets.only(left: spacing),
                                      child: Text(
                                        dateCenterLeft,
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
                                        dateCenterRight!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textStyle,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                            // No extra alignment or padding needed; Row fills width
                            alignment = Alignment.center;
                            padding = null;
                          } else {
                            // Non-date center text (time-of-day, "Now", etc.)
                            content = Text(
                              centerText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: textColor,
                                fontSize: fontSize,
                              ),
                            );
                            alignment = Alignment.center;
                            padding = EdgeInsets.symmetric(
                              horizontal: context.theme.spacing.md,
                            );
                          }
                        } else {
                          // Full width duration, right-aligned
                          content = _buildDurationContent(
                            context,
                            fontSize: fontSize,
                            durationText: durationText,
                            elapsedDuration: elapsedDuration,
                            remainingDuration: remainingDuration,
                            nowColor: nowColor,
                          );
                          alignment = Alignment.centerRight;
                          padding = EdgeInsets.only(
                            left: context.theme.spacing.md,
                          );
                        }

                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            // Background: Full-width line through header
                            // Skip line for event headers and date headers
                            if (widget.activity == null && widget.date == null)
                              Container(
                                height: 0.5,
                                margin: EdgeInsets.only(left: leadingIndent),
                                decoration: BoxDecoration(
                                  color: widget.now
                                      ? nowColor
                                      : context.theme.colors.border,
                                ),
                              ),
                            // Foreground: Single element with full width
                            // Date headers handle their own background per-text,
                            // so skip the outer background to keep the line visible.
                            Align(
                              alignment: alignment,
                              child: dateCenterLeft != null
                                  ? content
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: backgroundColor,
                                      ),
                                      padding: padding,
                                      child: content,
                                    ),
                            ),
                          ],
                        );
                      }

                      // Multiple elements: use adaptive flex ratio based on header type
                      // Date headers (1:4:1) - prioritize showing full date
                      // "Now" headers (2:2:2) - more space overall while keeping "Now" centered
                      // Other headers (1:2:1) - balanced layout
                      final int leftFlex;
                      final int centerFlex;
                      final int rightFlex;

                      if (widget.date != null) {
                        // Date headers: give more space to center to prevent date truncation
                        leftFlex = 1;
                        centerFlex = 4;
                        rightFlex = 1;
                      } else if (widget.now) {
                        // "Now" headers: equal flex keeps "Now" centered between
                        // elapsed (left) and remaining (right)
                        leftFlex = 2;
                        centerFlex = 2;
                        rightFlex = 2;
                      } else {
                        // Default: balanced layout
                        leftFlex = 1;
                        centerFlex = 2;
                        rightFlex = 1;
                      }

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // Background: Full-width line through header
                          // Skip line for event headers and date headers
                          if (widget.activity == null && widget.date == null)
                            Container(
                              height: 0.5,
                              margin: EdgeInsets.only(left: leadingIndent),
                              decoration: BoxDecoration(
                                color: widget.now
                                    ? nowColor
                                    : context.theme.colors.border,
                              ),
                            ),
                          // Foreground: 3-column layout
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // LEFT: Elapsed duration (now) or priority label
                              Flexible(
                                flex: leftFlex,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: hasLeft
                                      ? Container(
                                          decoration: BoxDecoration(
                                            color: backgroundColor,
                                          ),
                                          padding: EdgeInsets.only(
                                            right: context.theme.spacing.md,
                                          ),
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
                              // CENTER: Date/time
                              Expanded(
                                flex: centerFlex,
                                child: hasCenter
                                    ? dateCenterLeft != null
                                          // Date header: split into two halves centered on month
                                          ? Row(
                                              children: [
                                                Expanded(
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: Container(
                                                      color: backgroundColor,
                                                      padding: EdgeInsets.only(
                                                        left: context
                                                            .theme
                                                            .spacing
                                                            .md,
                                                      ),
                                                      child: Text(
                                                        dateCenterLeft,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: textColor,
                                                          fontSize: fontSize,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: Container(
                                                      color: backgroundColor,
                                                      padding: EdgeInsets.only(
                                                        right: context
                                                            .theme
                                                            .spacing
                                                            .md,
                                                      ),
                                                      child: Text(
                                                        dateCenterRight!,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: textColor,
                                                          fontSize: fontSize,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          // Non-date center text
                                          : Center(
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: backgroundColor,
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal:
                                                      context.theme.spacing.md,
                                                ),
                                                child: Text(
                                                  centerText!,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: textColor,
                                                    fontSize: fontSize,
                                                  ),
                                                ),
                                              ),
                                            )
                                    : Center(
                                        child: SizedBox(height: textHeight),
                                      ),
                              ),
                              // RIGHT: Remaining duration (now) or total duration
                              Flexible(
                                flex: rightFlex,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: hasRight
                                      ? Container(
                                          decoration: BoxDecoration(
                                            color: backgroundColor,
                                          ),
                                          padding: EdgeInsets.only(
                                            left: context.theme.spacing.md,
                                          ),
                                          child: widget.now
                                              ? Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      remainingDuration!
                                                          .format(),
                                                      style: TextStyle(
                                                        color: nowColor,
                                                        fontSize: fontSize,
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      width: context
                                                          .theme
                                                          .spacing
                                                          .xs,
                                                    ),
                                                    FaIcon(
                                                      PlotIcon.down,
                                                      size: fontSize,
                                                      color: nowColor,
                                                    ),
                                                  ],
                                                )
                                              : _buildDurationContent(
                                                  context,
                                                  fontSize: fontSize,
                                                  durationText: durationText,
                                                  elapsedDuration:
                                                      elapsedDuration,
                                                  remainingDuration:
                                                      remainingDuration,
                                                  nowColor: nowColor,
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
