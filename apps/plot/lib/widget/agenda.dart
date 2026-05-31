import 'dart:async';
// The app re-exports its own `Path` (via store.dart) which shadows
// `dart:ui`'s `Path` inside CustomPainters — use the `ui.` prefix there.
import 'dart:ui' as ui;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
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
import 'package:plot/util/priority_nav.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/priorities_shell.dart';
// `widget/link.dart` exports a `Link` widget that shadows the
// `package:plot/store/store.dart` data class we need here. Hide the
// widget so `Link.watchForThread(...)` resolves to the store type.
import 'package:plot/widget/widget.dart' hide Link;

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
  // Left breathing room plus the gutter→content gap. Keeping the right
  // gap ([agendaGutterGap]) wider than the left margin separates the
  // time/duration column from the titles beside it.
  final leftPad = context.theme.spacing.sm;
  return textWidth + leftPad + agendaGutterGap(context);
}

/// Horizontal gap between the leading time/duration gutter and the
/// title/summary content beside it. Shared by [agendaLeadingWidth] (which
/// budgets the column's width to include it) and every gutter's right
/// padding, so the time column and the content stay aligned across all
/// block types.
double agendaGutterGap(BuildContext context) => context.theme.spacing.md;

/// Line-height multiplier for the block header's fixed-height text rows.
///
/// Figtree's glyphs span ~1.2em (0.95 ascent + 0.25 descent). A line box
/// shorter than that ink shears off descenders ("g", "y", "p") — but only on
/// truncated lines, because `TextOverflow.ellipsis` makes `RenderParagraph`
/// clip its painting to its own line box once the text overflows the width.
/// Forcing `height: 1` made the box exactly 1em, one physical pixel short on
/// the descender side, so long-enough (ellipsized) summaries lost the bottom
/// of their text while short ones looked fine. 1.25 keeps the line box a hair
/// taller than the ink so descenders survive the clip, and it matches the
/// row boxes ([secondarySize] × this) so each paragraph fills its box exactly
/// with no overflow.
const _agendaRowLineHeight = 1.25;

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
    // Date parts for the day header: the full month + day lead, then the
    // full weekday, all left-aligned on one line.
    String? dateWeekday;
    String? dateMonth;
    String? dateDay;
    if (date != null) {
      // The label reads "May 28 Thursday" — full month + day, then the full
      // weekday — left-aligned on a single line. The whole label stays small
      // and quiet; only the day number is a touch bolder. The year is rarely
      // relevant in a near-term agenda, so it only appears (on the weekday)
      // when the date isn't in the current year. Computed even when [text] or
      // [dateTimeRange] is also set so the header can always render its label.
      dateWeekday = date!.year == Date.today().year
          ? date!.format(format: 'EEEE')
          : date!.format(format: 'EEEE yyyy');
      dateMonth = date!.format(format: 'MMMM');
      dateDay = date!.format(format: 'd');
    } else if (centerText == null && dateTimeRange != null) {
      // A gap in progress shows "Now"; otherwise its start time.
      if (now) {
        centerText = 'Now';
      } else {
        final timeOfDay = dateTimeRange!.start?.toTimeOfDay();
        if (timeOfDay != null && timeOfDay.isMidnight != true) {
          centerText = context.isMultiPanel
              ? timeOfDay.formatShort(context)
              : timeOfDay.formatNarrow(context);
        }
      }
    }

    // Determine if this gap touches a day boundary — the leading edge gap
    // (start at midnight) or the trailing one (end at midnight). Edge gaps
    // omit their duration; the leading one also renders no time, since a
    // midnight start has no label.
    bool gapTouchesMidnight = false;
    if (dateTimeRange != null && thread == null) {
      bool isMidnight(DateTime? t) =>
          t != null && t.hour == 0 && t.minute == 0 && t.second == 0;
      gapTouchesMidnight =
          isMidnight(dateTimeRange!.start) || isMidnight(dateTimeRange!.end);
    }

    // Determine duration text. A gap in progress shows its remaining free
    // time (end − now); otherwise the full gap duration.
    String? durationText;
    if (dateTimeRange != null && !gapTouchesMidnight) {
      if (now) {
        final end = dateTimeRange!.end;
        final currentTime = Time.now();
        if (end != null && end.isAfter(currentTime)) {
          final remaining = (end.difference(currentTime).inSeconds / 60).ceil();
          durationText = Duration(minutes: remaining).format();
        }
      } else if (dateTimeRange!.duration != null &&
          dateTimeRange!.duration!.inSeconds > 0) {
        durationText = dateTimeRange!.duration!.format();
      }
    }

    // No priority-context tint anymore — the universal agenda no longer
    // privileges a single priority for fallback time labels.
    final nowColor = context.theme.plotColors.veryMuted;

    final textColor = now ? nowColor : context.theme.plotColors.veryMuted;

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

    // Date headers separate each day with a quiet label: the month + day
    // sit in the leading gutter (left-aligned, column-aligned with the time
    // labels on event/gap rows), and the weekday sits in the content column
    // aligned with the titles beside it. One quiet tone and size throughout;
    // only the day number carries a slightly heavier weight.
    if (date != null) {
      final smSize = context.theme.typography.sm.fontSize;

      // One quiet tone and size for the whole label; the day number is the
      // only part with a heavier weight, so nothing competes with the
      // content titles beside it.
      final spacing = context.theme.spacing;
      final labelStyle = TextStyle(
        color: context.theme.plotColors.veryMuted,
        fontSize: smSize,
        fontWeight: FontWeight.w500,
      );
      final dayStyle = labelStyle.copyWith(
        color: context.theme.plotColors.muted,
        fontWeight: FontWeight.w700,
      );
      final priorityBloc = context.read<PriorityBloc>();

      // The day number is always shown; the month falls back to its short
      // form (e.g. "Sep") when the full name would overflow the narrow
      // gutter. Measure the bold "<month> <day>" against the gutter's text
      // area (its width minus the gutter→content gap).
      final timeColWidth = agendaLeadingWidth(context);
      final available = timeColWidth - agendaGutterGap(context);
      final monthFull = dateMonth!;
      final fullWidth = (TextPainter(
        text: TextSpan(
          text: '$monthFull ${dateDay!}',
          style: TextStyle(fontSize: smSize, fontWeight: FontWeight.w700),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout()).width;
      final monthText = fullWidth <= available
          ? monthFull
          : date!.format(format: 'MMM');

      // A subtle full-width band sets each day apart; the symmetric vertical
      // padding keeps the label breathing inside it. The whole row is a tap
      // target that schedules a focus block on this day, with the trailing +
      // hidden until hover on non-touch devices.
      return _AddHeaderRow(
        command: OpenScheduleFocusModal(
          date: date!,
          defaultPriority: priorityBloc.state.context,
        ),
        addColor: context.theme.plotColors.veryMuted,
        background: context.colour.sectionHeaderBackground,
        outerPadding: EdgeInsets.symmetric(vertical: spacing.sm),
        leading: [
          // Gutter: "May 28" — right-aligned, column-aligned with the leading
          // time labels on event/gap rows (right padding = the gutter→content
          // gap so the weekday lines up with the titles beside it).
          SizedBox(
            width: timeColWidth,
            child: Padding(
              padding: EdgeInsets.only(right: agendaGutterGap(context)),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '$monthText ', style: labelStyle),
                      TextSpan(text: dateDay, style: dayStyle),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          // Weekday in the content column, aligned with the titles on other
          // rows. The + button stays vertically centred at the trailing edge.
          Expanded(
            child: Text(
              dateWeekday!,
              style: labelStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // Empty gap rows render through [_GapHeaderRow]: a quiet time +
    // free-time-duration line whose duration is overlaid by a + (on hover
    // on non-touch, always on touch) that schedules a focus block in the
    // gap. The whole row is the tap target.
    if (isGapHeader) {
      // Anchor the new focus block at the gap's start. A gap that's already
      // in progress (start in the past) or a leading edge gap (whose start
      // is just the midnight day boundary) falls back to the form's default
      // time for the day; either way the default duration is capped to the
      // free time remaining in the gap.
      final priorityBloc = context.read<PriorityBloc>();
      final gapStart = dateTimeRange!.start;
      final gapEnd = dateTimeRange!.end;
      final nowTime = Time.now();
      final startIsMidnight =
          gapStart != null &&
          gapStart.hour == 0 &&
          gapStart.minute == 0 &&
          gapStart.second == 0;
      final DateTime? startForModal =
          (gapStart != null && !startIsMidnight && gapStart.isAfter(nowTime))
          ? gapStart
          : null;
      // Anchors the modal's date (and the duration cap). For the leading
      // edge gap this is midnight — the correct day — while [startForModal]
      // stays null so the form picks the day's default time.
      final effStart = startForModal ?? gapStart ?? nowTime;
      final Duration? maxDur = (gapEnd != null && gapEnd.isAfter(effStart))
          ? gapEnd.difference(effStart)
          : null;

      return _GapHeaderRow(
        command: OpenScheduleFocusModal(
          date: Date(effStart.year, effStart.month, effStart.day),
          defaultPriority: priorityBloc.state.context,
          start: startForModal,
          maxDuration: maxDur,
        ),
        timeText: centerText,
        durationText: durationText,
      );
    }

    // Plain text section headings (e.g. Activity tab "Today", "New",
    // "Scheduled", "Done") and non-now event time headers: centered time,
    // rendered outside ListTile to match date header centering.
    if (!now && date == null && centerText != null) {
      final veryMuted = context.theme.plotColors.veryMuted;
      final timeStyle = TextStyle(color: textColor, fontSize: fontSize);

      // Match the ThreadWidget time position: the time right edge
      // aligns with the logo right edge (= agendaLeadingWidth).
      final timeColWidth = agendaLeadingWidth(context);

      final Widget child;
      if (dateTimeRange == null) {
        // Plain text section heading — center, not in the time column.
        child = Center(
          child: Text(
            centerText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: timeStyle.copyWith(fontWeight: FontWeight.w500),
          ),
        );
      } else {
        // Match the ListTile's right padding so duration aligns with
        // the thread tag button icons.
        final isWide = context.isMultiPanel;
        child = Padding(
          padding: EdgeInsets.only(
            right: isWide
                ? context.theme.spacing.lg
                : context.theme.buttonStyles.ghost.md.iconContentStyle.padding
                      .resolve(TextDirection.ltr)
                      .right,
          ),
          child: Row(
            children: [
              SizedBox(
                width: timeColWidth,
                child: Padding(
                  padding: EdgeInsets.only(right: agendaGutterGap(context)),
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

      // Text-only section headings render as quiet dividers — no fill, just
      // a muted centered label, relying on the preceding row's bottom border
      // for separation — sharing the same visual language as the agenda date
      // headers above.
      final isTextOnlyHeading = dateTimeRange == null;
      Widget result;
      if (isTextOnlyHeading) {
        result = DecoratedBox(
          decoration: BoxDecoration(
            color: context.colour.sectionHeaderBackground,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
            child: child,
          ),
        );
      } else {
        result = Padding(
          padding: EdgeInsets.symmetric(vertical: verticalMargin),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
            child: child,
          ),
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
            padding: EdgeInsets.symmetric(vertical: context.theme.spacing.sm),
            child: SizedBox(
              width: timeColWidth,
              child: Padding(
                padding: EdgeInsets.only(right: agendaGutterGap(context)),
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

/// An agenda section header (a date divider or an empty-gap row) that
/// carries a trailing `+` for scheduling a focus block. The whole row is a
/// tap target running [command]; on non-touch devices the `+` is hidden
/// until the row is hovered, while touch devices always show it (there is
/// no hover to reveal it). [leading] fills the row up to the trailing `+`.
class _AddHeaderRow extends StatefulWidget {
  const _AddHeaderRow({
    required this.command,
    required this.leading,
    required this.addColor,
    required this.outerPadding,
    this.background,
  });

  /// Run by both the trailing `+` button and a tap anywhere on the row.
  final Command command;

  /// Row children rendered before the trailing `+`.
  final List<Widget> leading;

  /// Colour of the trailing `+` icon.
  final Color addColor;

  /// Padding wrapping the [Row] — vertical breathing room for the header.
  final EdgeInsetsGeometry outerPadding;

  /// Optional fill painted behind the whole row (date headers use the
  /// section-header background; empty gaps stay unfilled).
  final Color? background;

  @override
  State<_AddHeaderRow> createState() => _AddHeaderRowState();
}

class _AddHeaderRowState extends State<_AddHeaderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final touch = isTouchPlatform();
    // A small right inset lands the icon at the agenda's trailing edge.
    final addButton = Padding(
      padding: EdgeInsets.only(right: context.theme.spacing.sm),
      child: Button.icon(widget.command, color: widget.addColor),
    );
    // Non-touch: keep the `+` laid out (so the row width never shifts when
    // it appears) and fade it in only on hover. Touch: always visible.
    final trailing = touch
        ? addButton
        : AnimatedOpacity(
            opacity: _hovered ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: addButton,
          );

    Widget content = Padding(
      padding: widget.outerPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [...widget.leading, trailing],
      ),
    );

    final bg = widget.background;
    if (bg != null) {
      content = DecoratedBox(
        decoration: BoxDecoration(color: bg),
        child: content,
      );
    }

    Widget result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.run(widget.command),
      child: content,
    );

    if (!touch) {
      result = MouseRegion(
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: result,
      );
    }
    return result;
  }
}

/// Empty-gap agenda row: a quiet time + free-time-duration line whose
/// trailing duration is overlaid — on hover (non-touch) or always (touch)
/// — by a + that schedules a focus block in the gap. The + is layered over
/// the duration (a [Stack], mirroring the [_BlockHeader] gutter affordance)
/// so it never reflows the row; the row height ([rowHeight] + symmetric
/// [spacing.md]) and the trailing edge ([rightPad]) match the event rows
/// so gaps and events read at the same rhythm. The whole row is the tap
/// target running [command].
class _GapHeaderRow extends StatefulWidget {
  const _GapHeaderRow({
    required this.command,
    required this.timeText,
    required this.durationText,
  });

  /// Run by a tap anywhere on the row (and surfaced as the overlaid +).
  final Command command;

  /// Gutter time label ("Now", a start time, or null at midnight).
  final String? timeText;

  /// Free-time label shown at the trailing edge, or null (e.g. the last
  /// gap of the day, which runs to midnight).
  final String? durationText;

  @override
  State<_GapHeaderRow> createState() => _GapHeaderRowState();
}

class _GapHeaderRowState extends State<_GapHeaderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    final veryMuted = context.theme.plotColors.veryMuted;
    final fontSize = context.theme.typography.sm.fontSize ?? 13;
    final rowHeight = fontSize * _agendaRowLineHeight;
    final timeColWidth = agendaLeadingWidth(context);
    final isWide = context.isMultiPanel;
    // Land the trailing duration/edit affordance at the same x as the event
    // rows' trailing durations (see [_BlockHeader.rightPad]).
    final rightPad = isWide
        ? spacing.lg
        : context.theme.buttonStyles.ghost.md.iconContentStyle.padding
              .resolve(TextDirection.ltr)
              .right;
    final touch = isTouchPlatform();
    final showPlus = touch || _hovered;
    final textStyle = TextStyle(
      color: veryMuted,
      fontSize: fontSize,
      height: _agendaRowLineHeight,
    );

    final gutter = SizedBox(
      width: timeColWidth,
      child: Padding(
        padding: EdgeInsets.only(right: agendaGutterGap(context)),
        child: SizedBox(
          height: rowHeight,
          child: widget.timeText != null
              ? Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    widget.timeText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );

    // The duration and the + share one trailing slot. The + fades in over
    // the duration (which fades out), so the duration's resting position
    // never moves and the row never reflows. The slot plus the outer
    // [rightPad] together span the gutter's width ([timeColWidth]), so the
    // squiggle's [Expanded] ends exactly [timeColWidth] from the panel's
    // right edge — mirroring the leading gutter and centring the squiggle.
    // The duration stays right-aligned at the same x (the rightPad edge), so
    // resizing the slot doesn't shift it.
    final trailing = SizedBox(
      width: timeColWidth - rightPad,
      height: rowHeight,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          AnimatedOpacity(
            opacity: showPlus ? 0 : 1,
            duration: const Duration(milliseconds: 120),
            child: widget.durationText != null
                ? Text(
                    widget.durationText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                  )
                : const SizedBox.shrink(),
          ),
          IgnorePointer(
            ignoring: !showPlus,
            child: AnimatedOpacity(
              opacity: showPlus ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Icon(PlotIcon.add, size: fontSize, color: veryMuted),
            ),
          ),
        ],
      ),
    );

    Widget result = Padding(
      padding: EdgeInsets.only(
        top: spacing.md,
        bottom: spacing.md,
        right: rightPad,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          gutter,
          // Title area: a quiet wavy squiggle marks the empty free-time
          // span where an event/focus title would sit. It fills the slot
          // between the gutter and the trailing duration column; with that
          // column sized so the right margin equals the gutter, the squiggle
          // sits centred with equal margins on both sides and never reflows
          // when the duration swaps to the + on hover.
          Expanded(
            child: SizedBox(
              height: rowHeight,
              child: CustomPaint(
                painter: _SquigglePainter(
                  // Half the muted tone's opacity — a faint, easily
                  // ignored marker rather than a strong rule.
                  color: veryMuted.withValues(alpha: veryMuted.a * 0.5),
                ),
                size: Size.infinite,
              ),
            ),
          ),
          trailing,
        ],
      ),
    );

    result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.run(widget.command),
      child: result,
    );

    if (!touch) {
      result = MouseRegion(
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: result,
      );
    }
    return result;
  }
}

/// Paints a gentle horizontal wave across its width — the empty-title
/// marker for [_GapHeaderRow]. Drawn as a run of alternating quadratic
/// half-waves (each peaks at ±[_amplitude] over its midpoint) so the line
/// reads as a smooth squiggle. Uses `ui.Path` because the app's own `Path`
/// (re-exported via store.dart) shadows `dart:ui`'s here.
class _SquigglePainter extends CustomPainter {
  const _SquigglePainter({required this.color});

  final Color color;

  static const double _wavelength = 16;
  static const double _amplitude = 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final midY = size.height / 2;
    final half = _wavelength / 2;
    final path = ui.Path()..moveTo(0, midY);
    var x = 0.0;
    var up = true;
    while (x < size.width) {
      final endX = (x + half) > size.width ? size.width : x + half;
      final ctrlX = (x + endX) / 2;
      final ctrlY = midY + (up ? -_amplitude : _amplitude) * 2;
      path.quadraticBezierTo(ctrlX, ctrlY, endX, midY);
      x = endX;
      up = !up;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SquigglePainter oldDelegate) =>
      oldDelegate.color != color;
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

  /// `(start, end)` for the block this header introduces. Reads the
  /// uniform `start`/`end` getters added on `AgendaBlock`.
  ({DateTime start, DateTime end}) get _blockWindow {
    final b = widget.block;
    return (start: b.start, end: b.end);
  }

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
    final editableChanged =
        _blockHasEditablePending(oldWidget.block) !=
        _blockHasEditablePending(widget.block);
    final priorityChanged = oldWidget.priority.id != widget.priority.id;
    // Window comparison only matters for blocks where the subscription
    // is live; reading start/end on blocks without time anchors throws.
    final windowChanged =
        _blockHasEditablePending(widget.block) &&
        _blockHasEditablePending(oldWidget.block) &&
        (oldWidget.block.start != widget.block.start ||
            oldWidget.block.end != widget.block.end);
    if (priorityChanged || editableChanged || windowChanged) {
      _pendingSub?.cancel();
      _pendingDisplay = null;
      _subscribePending();
    }
  }

  /// True for blocks whose lead priority owns an editable pending
  /// duration in the gutter. Only user-scheduled focus blocks
  /// ([PriorityBlock]s) qualify; events and read-only gaps do not.
  static bool _blockHasEditablePending(AgendaBlock block) =>
      block is PriorityBlock;

  @override
  void dispose() {
    _tick?.cancel();
    _pendingSub?.cancel();
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
  }

  void _subscribePending() {
    if (!_blockHasEditablePending(widget.block)) return;
    final w = _blockWindow;
    _pendingSub =
        NowBloc.watchBlockDisplay(
          priorityId: widget.priority.id,
          blockStart: w.start,
          blockEnd: w.end,
        ).listen((d) {
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

    final mutedFg = context.colour.colours.fromTheme(
      priority.displayColor,
      muted: true,
    );
    final fg = widget.selected
        ? context.colour.colours.fromTheme(priority.displayColor)
        : mutedFg;
    final bg = widget.selected
        ? context.colour.colours.backgroundFromTheme(priority.displayColor)
        : _isHovered
        ? context.colour.editableBackground
        : context.colour.background;
    final spacing = context.theme.spacing;
    // Both header lines render at the activity feed's sm size: the primary
    // line (priority breadcrumb / event title) and the secondary line
    // (summary, time, duration, RSVP, active-timing) share one quiet scale,
    // with hierarchy coming from colour rather than size.
    final secondarySize = context.theme.typography.sm.fontSize ?? 13;

    final hasTime = dateTimeRange != null;
    final timeOfDay = dateTimeRange?.start?.toTimeOfDay();
    // Show a midnight (12:00 am) start time for genuinely time-scheduled
    // rows — user-scheduled focus blocks and timed events — instead of
    // omitting it. All-day events keep no time label: their start is
    // midnight only because they carry a date (`on`), not a time-of-day.
    final showMidnightStart = block is PriorityBlock ||
        (block is EventBlock && block.event.on == null);
    // An event/block/gap in progress shows "Now" in the gutter instead of
    // its start time.
    final timeText = widget.now
        ? 'Now'
        : (hasTime &&
                  timeOfDay != null &&
                  (!timeOfDay.isMidnight || showMidnightStart)
              ? (context.isMultiPanel
                    ? timeOfDay.formatShort(context)
                    : timeOfDay.formatNarrow(context))
              : null);

    final summary = block.summaryLine;
    final isEvent = block is EventBlock;

    // For event blocks, row 1 is the event title rendered in the
    // priority's foreground color (replacing the priority breadcrumb —
    // the colour itself signals which priority the event belongs to).
    // Row 2 surfaces the event's physical location and/or
    // videoconferencing join link via a [StreamBuilder] over the event
    // thread's links. For non-event blocks, row 1 keeps the priority
    // breadcrumb (a [FocusLabel], which carries its own leading focus
    // icon) and row 2 keeps the joined thread summary.
    final mutedColor = context.theme.plotColors.veryMuted;
    final TextSpan summarySpan = TextSpan(
      text: summary,
      style: TextStyle(color: mutedColor),
    );

    // Row 2 trailing widget: RSVP summary, right-padded so its visible
    // edge lands at the same x as the right edge of the content area.
    Widget? row2Trailing;
    if (thread != null && thread.hasOtherAttendees) {
      row2Trailing = RsvpChip(
        activity: thread,
        fontSize: context.theme.typography.xs.fontSize,
      );
    }

    final timeColWidth = agendaLeadingWidth(context);

    // Right padding lands trailing items at the agenda's outer edge.
    final isWide = context.isMultiPanel;
    final iconPad = context.theme.buttonStyles.ghost.md.iconContentStyle.padding
        .resolve(TextDirection.ltr);
    final rightPad = isWide ? spacing.lg : iconPad.right;

    // The duration label lives on the right side of row 1 in all cases
    // (column-aligned with the gap headers' trailing duration). For an
    // event, focus block, or gap in progress ([widget.now]) the static
    // duration is replaced with the remaining time (end − now, ceil to
    // whole minutes) so it counts down toward 0. The per-minute tick in
    // [_scheduleTick] (gated on [widget.now]) keeps it fresh.
    final currentTime = Time.now();
    final blockEnd = dateTimeRange?.end;
    Duration? remainingNow;
    if (widget.now && blockEnd != null && blockEnd.isAfter(currentTime)) {
      remainingNow = Duration(
        minutes: (blockEnd.difference(currentTime).inSeconds / 60).ceil(),
      );
    }

    final Duration? displayedDuration;
    if (block is PriorityBlock) {
      // A user-scheduled focus block surfaces its duration on row 1.
      // [NowBloc.watchBlockDisplay] overlays an active or paused-explicit
      // session's live remaining; with no session it emits null and we
      // fall back to the in-progress remaining, then the block's own
      // scheduled duration.
      displayedDuration =
          _pendingDisplay?.duration ?? remainingNow ?? block.cascadeDuration;
    } else if (widget.now) {
      // In-progress event or priority-led gap → remaining time.
      displayedDuration = remainingNow;
    } else {
      displayedDuration = dateTimeRange?.duration;
    }

    Widget? durationWidget;
    if (displayedDuration != null && displayedDuration.inSeconds > 0) {
      durationWidget = Text(
        _formatDuration(displayedDuration),
        style: TextStyle(
          fontSize: secondarySize,
          color: mutedColor,
          height: _agendaRowLineHeight,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final rowHeight = secondarySize * _agendaRowLineHeight;

    // Show the gutter edit affordance only for blocks that map cleanly
    // to a focus-block create/edit action — priority blocks (already
    // backed by a row when sourceRow is set, or pre-fillable when not)
    // and gap blocks with a priority lead.
    final canEditAsFocusBlock = block is PriorityBlock || block is GapBlock;

    // The gutter carries only the time now (the duration moved to row 1's
    // trailing edge), so it is a single line aligned with the title.
    final gutterColumn = SizedBox(
      width: timeColWidth,
      child: Padding(
        padding: EdgeInsets.only(right: agendaGutterGap(context)),
        child: SizedBox(
          height: rowHeight,
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
                      height: _agendaRowLineHeight,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );

    final Widget gutter;
    if (canEditAsFocusBlock) {
      gutter = Stack(
        alignment: Alignment.center,
        children: [
          AnimatedOpacity(
            opacity: _isHovered ? 0 : 1,
            duration: const Duration(milliseconds: 120),
            child: gutterColumn,
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isHovered,
              child: AnimatedOpacity(
                opacity: _isHovered ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Center(
                  child: GestureDetector(
                    onTap: () => _openFocusBlockEditor(context),
                    behavior: HitTestBehavior.opaque,
                    child: Icon(
                      PlotIcon.edit,
                      size: secondarySize,
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      gutter = gutterColumn;
    }

    // Row 1: time (gutter) · title · duration. Always present.
    final firstRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        gutter,
        Expanded(
          child: SizedBox(
            height: rowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: isEvent
                  ? Text(
                      block.event.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: secondarySize,
                        height: _agendaRowLineHeight,
                      ),
                    )
                  // [FocusLabel] renders its own leading focus icon (the
                  // priority's chosen glyph), so no separate icon is added
                  // here — doing so produced a duplicate icon on
                  // [PriorityBlock] headers.
                  : FocusLabel(
                      priority: priority,
                      color: fg,
                      fontSize: secondarySize,
                      height: _agendaRowLineHeight,
                    ),
            ),
          ),
        ),
        if (durationWidget != null) ...[
          SizedBox(width: spacing.sm),
          durationWidget,
        ],
      ],
    );

    // Row 2 is indented to start under the title (past the gutter) and
    // only renders when it has content. For non-events the content is the
    // synchronous summary, so we decide here. Events resolve their
    // location / videoconferencing line asynchronously from the link
    // stream, so [_EventSecondRow] makes that decision reactively and
    // collapses to nothing (no blank line) when an event has no location,
    // conferencing, preview, or RSVP to show.
    Widget? secondRow;
    if (isEvent) {
      secondRow = _EventSecondRow(
        event: block.event,
        indent: timeColWidth,
        topGap: spacing.sm,
        gap: spacing.sm,
        rowHeight: rowHeight,
        mutedColor: mutedColor,
        fontSize: secondarySize,
        trailing: row2Trailing,
      );
    } else if (summary.isNotEmpty || row2Trailing != null) {
      secondRow = Padding(
        padding: EdgeInsets.only(top: spacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: timeColWidth),
            Expanded(
              child: SizedBox(
                height: rowHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: summary.isNotEmpty
                      ? Text.rich(
                          summarySpan,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: secondarySize,
                            height: _agendaRowLineHeight,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            if (row2Trailing != null) ...[
              SizedBox(width: spacing.sm),
              row2Trailing,
            ],
          ],
        ),
      );
    }

    final innerRow = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [firstRow, ?secondRow],
    );

    return Container(
      color: bg,
      padding: EdgeInsets.only(
        top: spacing.md,
        bottom: spacing.md,
        right: trailingHandle != null ? 0 : rightPad,
      ),
      child: trailingHandle == null
          ? innerRow
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: innerRow),
                trailingHandle,
              ],
            ),
    );
  }

  /// Open the schedule-focus modal for this block. Edit mode is used when
  /// (a) the block carries an explicit [PriorityBlock.sourceRow] (focus
  /// blocks inserted by [_insertExplicitFocusBlocks]) or (b) a
  /// non-archived `priority_block` row with positive duration exists at
  /// the block's window start (legacy bump/reorder rows that still
  /// contribute a cascade duration). Otherwise create mode pre-fills the
  /// block's priority + window.
  Future<void> _openFocusBlockEditor(BuildContext context) async {
    final block = widget.block;
    if (block is! PriorityBlock && block is! GapBlock) return;
    PriorityBlockRow? row = block is PriorityBlock ? block.sourceRow : null;
    row ??= await _lookupExistingFocusRow(
      priorityId: block.priority.id,
      at: block.start,
    );
    if (!context.mounted) return;
    if (row != null) {
      await openScheduleFocusModal(
        context,
        existingRow: row,
        initialPriority: block.priority,
      );
      return;
    }
    final w = _blockWindow;
    final dateForCreate = Date(w.start.year, w.start.month, w.start.day);
    await openScheduleFocusModal(
      context,
      date: dateForCreate,
      initialPriority: block.priority,
    );
  }

  /// Returns the most recent non-archived `priority_block` row with
  /// positive duration for [priorityId] whose `effective_at` matches [at]
  /// (or, when nothing matches exactly, any positive-duration row for the
  /// priority on the same calendar day). Null when no candidate exists.
  Future<PriorityBlockRow?> _lookupExistingFocusRow({
    required PriorityId priorityId,
    required DateTime at,
  }) async {
    if (!Store.isAvailable) return null;
    final table = Store.get.priorityBlocks;
    final dayStart = DateTime(at.year, at.month, at.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final rows = await (Store.get.select(
      table,
    )..where((t) => t.priorityId.equals(priorityId.toBytes()))).get();
    final candidates = rows
        .where(
          (r) =>
              r.archivedAt == null &&
              r.duration != null &&
              r.duration! > Duration.zero &&
              !r.effectiveAt.isBefore(dayStart) &&
              r.effectiveAt.isBefore(dayEnd),
        )
        .toList();
    if (candidates.isEmpty) return null;
    final exact = candidates.firstWhere(
      (r) => r.effectiveAt.isAtSameMomentAs(at),
      orElse: () => candidates.first,
    );
    return exact;
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
            // Direct agenda selection: highlight exactly this block, even
            // when it isn't the block covering the current time.
            context.run(
              ChangeCurrentPriority(
                widget.priority,
                selectedBlockId: widget.parentBlockId,
              ),
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
          // Record the source tab so back from the destination priority
          // page returns to Agenda instead of exiting the app. Mark for
          // URL-history replace when already on the Activity tab so an
          // in-tab event swap doesn't accumulate URL history.
          TabsRouter? tabsRouter;
          try {
            tabsRouter = AutoTabsRouter.of(context);
          } catch (_) {
            // AutoTabsRouter not in scope.
          }
          PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
            activeTabIndex: tabsRouter?.activeIndex,
            currentSourceTab: PrioritiesShell.sourceTab,
          );
          if (isOnActivityTab(tabsRouter)) {
            context.router.root.navigationHistory.markUrlStateForReplace();
          }
          final targetPriorityIdString = eventThread.priority.id
              .toShortString();
          final targetThreadIdString = eventThread.id.toShortString();
          // Same-priority fast path: when PriorityRoute(target) is already
          // mounted on the Activity tab, `root.navigate(PriorityRoute(X,
          // children: [ThreadRoute(...)]))` hits auto_route's in-place
          // params update — it drops the existing inner route
          // (PriorityOnlyRoute / ThreadRoute) without mounting the new
          // ThreadRoute, leaving the inner AutoRouter empty so it falls
          // back to LoadingPage → forever spinner. Skip the navigate and
          // drive the inner stack explicitly.
          if (isSamePriorityAtActivityTop(
            tabsRouter: tabsRouter,
            targetPriorityIdString: targetPriorityIdString,
            priorityRouteName: PriorityRoute.name,
          )) {
            if (tabsRouter!.activeIndex != PriorityTabs.activity) {
              tabsRouter.setActiveIndex(PriorityTabs.activity);
            }
            final innerRouter = findPriorityInnerRouter(
              context.router.root,
              PriorityRoute.name,
            );
            if (innerRouter != null) {
              innerRouter.replaceAll([
                ThreadRoute(threadIdString: targetThreadIdString),
              ]);
              return;
            }
          }
          // Use the root router: when triggered from the Agenda tab,
          // `context.router` is the agenda's nested StackRouter which has
          // no PriorityRoute in its tree (PriorityRoute lives under the
          // Activity tab's ActivityShell), so a scoped navigate throws
          // `Failed to navigate to PriorityRoute`. The root navigator
          // resolves the cross-tab path and handles the tab swap.
          context.router.root.navigate(
            PriorityRoute(
              priorityIdString: targetPriorityIdString,
              children: [ThreadRoute(threadIdString: targetThreadIdString)],
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
          // [Swipeable] nests inside the [LongPressDraggable] so the
          // horizontal drag claims the gesture arena at hit-slop while
          // the long-press still wins the drag — same pattern the
          // activity feed uses. See [_SwipeHorizontalDragRecognizer].
          final source = KeyedSubtree(
            key: _sourceKey,
            child: _buildRow(context),
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

/// Row 2 for calendar event blocks. Watches the event thread's links to
/// surface a physical location, a videoconferencing join link, or both,
/// falling back to [Thread.displayPreview] when neither is present so the
/// row still carries useful context (e.g. user notes on the event).
///
/// The whole row is reactive: when an event has no location, conferencing,
/// preview, *and* no [trailing] RSVP, it collapses to nothing rather than
/// reserving a blank second line. The row is indented by [indent] (the
/// gutter width) so its content lines up under the title.
class _EventSecondRow extends StatelessWidget {
  const _EventSecondRow({
    required this.event,
    required this.indent,
    required this.topGap,
    required this.gap,
    required this.rowHeight,
    required this.mutedColor,
    required this.fontSize,
    required this.trailing,
  });

  final Thread event;
  final double indent;
  final double topGap;
  final double gap;
  final double rowHeight;
  final Color mutedColor;
  final double fontSize;
  final Widget? trailing;

  /// The location / conferencing / preview content for [event] built from
  /// its [links], or null when the event has nothing to show. Returning
  /// null (rather than an empty box) lets the caller decide whether the
  /// row should appear at all.
  Widget? _content(BuildContext context, List<Link> links) {
    String? location;
    for (final link in links) {
      final raw = link.meta?['location'];
      if (raw is String && raw.trim().isNotEmpty) {
        location = raw.trim();
        break;
      }
    }

    ConferencingUserAction? conf;
    for (final link in links) {
      for (final action in link.actions ?? const <UserAction>[]) {
        if (action is ConferencingUserAction) {
          conf = action;
          break;
        }
      }
      if (conf != null) break;
    }

    final spacing = context.theme.spacing;

    if (conf != null && location == null) {
      return _ConferencingInline(
        action: conf,
        color: mutedColor,
        fontSize: fontSize,
        withLabel: true,
      );
    }

    if (conf != null && location != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ConferencingInline(
            action: conf,
            color: mutedColor,
            fontSize: fontSize,
            withLabel: false,
          ),
          SizedBox(width: spacing.sm),
          Flexible(
            child: _LocationInline(
              location: location,
              color: mutedColor,
              fontSize: fontSize,
            ),
          ),
        ],
      );
    }

    if (location != null) {
      return _LocationInline(
        location: location,
        color: mutedColor,
        fontSize: fontSize,
      );
    }

    final preview = event.displayPreview;
    if (preview != null && preview.isNotEmpty) {
      return Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          color: mutedColor,
          height: _agendaRowLineHeight,
        ),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Link>>(
      stream: Link.watchForThread(event.id),
      builder: (context, snapshot) {
        final content = _content(context, snapshot.data ?? const <Link>[]);

        // No content and no RSVP → no second line at all.
        if (content == null && trailing == null) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: EdgeInsets.only(top: topGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: indent),
              Expanded(
                child: SizedBox(
                  height: rowHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: content ?? const SizedBox.shrink(),
                  ),
                ),
              ),
              if (trailing != null) ...[SizedBox(width: gap), trailing!],
            ],
          ),
        );
      },
    );
  }
}

/// Clickable inline videoconferencing affordance. Renders the logo
/// alone when [withLabel] is false (paired with a physical location);
/// renders logo + provider name when [withLabel] is true (only
/// videoconferencing, no physical location).
///
/// On hover the label underlines and both icon and text strengthen from
/// the resting muted tone to [PlotColors.muted], signalling that the row
/// is a true (external) link the user can click to join.
class _ConferencingInline extends StatefulWidget {
  const _ConferencingInline({
    required this.action,
    required this.color,
    required this.fontSize,
    required this.withLabel,
  });

  final ConferencingUserAction action;
  final Color color;
  final double fontSize;
  final bool withLabel;

  static String _providerName(ConferencingProvider provider) {
    switch (provider) {
      case ConferencingProvider.googleMeet:
        return 'Google Meet';
      case ConferencingProvider.zoom:
        return 'Zoom';
      case ConferencingProvider.microsoftTeams:
        return 'Microsoft Teams';
      case ConferencingProvider.webex:
        return 'Webex';
      case ConferencingProvider.other:
        return 'Meeting';
    }
  }

  @override
  State<_ConferencingInline> createState() => _ConferencingInlineState();
}

class _ConferencingInlineState extends State<_ConferencingInline> {
  bool _hovered = false;

  void _open() {
    try {
      launchUrl(
        Uri.parse(widget.action.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.theme.spacing;
    final provider = widget.action.provider;
    final tooltip = 'Join ${_ConferencingInline._providerName(provider)}';
    // Strengthen from the resting muted tone on hover so the link reads
    // as interactive without shifting layout.
    final color = _hovered ? context.theme.plotColors.muted : widget.color;

    // Render the glyph as a real inline character in the label's text run —
    // a [TextSpan] in the icon font, not an [Icon] wrapped in a [WidgetSpan].
    // A [WidgetSpan] forces the icon into its own `height: 1.0` box and then
    // `PlaceholderAlignment.middle` re-centers that box on the *line* box,
    // which is `_agendaRowLineHeight` (1.25) tall — so its geometric centre
    // sits a fraction above the text glyphs' optical centre and the icon
    // floats high (more obvious with the wide, rectangular camcorder glyph).
    // As an inline glyph it shares the run's font size and line height, so
    // Font Awesome's own baseline metrics land it on the same optical line as
    // the label, identically in every row.
    final content = widget.withLabel
        ? Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: String.fromCharCode(PlotIcon.video.codePoint),
                  style: TextStyle(
                    fontFamily: PlotIcon.video.fontFamily,
                    package: PlotIcon.video.fontPackage,
                  ),
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SizedBox(width: spacing.sm),
                ),
                TextSpan(text: _ConferencingInline._providerName(provider)),
              ],
              style: TextStyle(
                fontSize: widget.fontSize,
                color: color,
                height: _agendaRowLineHeight,
              ),
            ),
          )
        : Icon(PlotIcon.video, size: widget.fontSize, color: color);

    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(onTap: _open, child: content),
      ),
    );
  }
}

/// Inline physical-location label. Address-like strings (containing a
/// comma) open a Google Maps search on tap; bare meeting-room names
/// render as plain text. The heuristic is intentionally conservative —
/// a missed address is a minor inconvenience, a wrongly-clickable
/// meeting room would mislead.
class _LocationInline extends StatelessWidget {
  const _LocationInline({
    required this.location,
    required this.color,
    required this.fontSize,
  });

  final String location;
  final Color color;
  final double fontSize;

  bool get _looksLikeAddress => location.contains(',');

  void _open() {
    final q = Uri.encodeQueryComponent(location);
    try {
      launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      location,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        height: _agendaRowLineHeight,
      ),
    );
    if (!_looksLikeAddress) return textWidget;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: _open, child: textWidget),
    );
  }
}
