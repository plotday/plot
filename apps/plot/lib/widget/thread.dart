import 'dart:async';


import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/state/priority.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/util/hooks.dart';
import 'package:url_launcher/url_launcher.dart';

class ThreadWidget extends StatefulWidget {
  const ThreadWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.now = false,
    this.isNext = false,
    this.showSubPriority = false,
    this.showEventTiming = false,
    this.bump = true,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.onSwipeExit,
    this.onDesktopFinish,
    super.key,
  });

  final Thread activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final bool now;
  final bool isNext;
  final bool showSubPriority;
  final bool showEventTiming;
  final bool bump;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;
  final Future<void> Function(Command command)? onSwipeExit;

  /// Called before a finish command runs on desktop (icon click path).
  /// Should trigger the fade+collapse removal animation.
  final Future<void> Function()? onDesktopFinish;

  @override
  State<ThreadWidget> createState() => _ThreadWidgetState();
}

class _ThreadWidgetState extends State<ThreadWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimerIfNeeded();
  }

  @override
  void didUpdateWidget(ThreadWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.now != widget.now || oldWidget.isNext != widget.isNext) {
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
    if (!widget.now && !widget.isNext) return;
    final now = Time.now();
    final secondsUntilNextMinute = 60 - now.second;
    _timer = Timer(Duration(seconds: secondsUntilNextMinute), () {
      if (mounted) {
        setState(() {});
        _timer = Timer.periodic(const Duration(minutes: 1), (_) {
          if (mounted) {
            setState(() {});
          }
        });
      }
    });
  }

  Thread get activity => widget.activity;
  Priority? get priorityContext => widget.context;
  bool get highlighted => widget.highlighted;
  bool get selected => widget.selected;
  bool get now => widget.now;
  bool get isNext => widget.isNext;
  bool get showSubPriority => widget.showSubPriority;
  bool get showEventTiming => widget.showEventTiming;
  bool get bump => widget.bump;
  FocusNode? get focusNode => widget.focusNode;
  void Function(bool hovered)? get onHover => widget.onHover;
  int? get reorderableIndex => widget.reorderableIndex;

  // Short right: Start (only if not already started/user-scheduled)
  Command? _getSwipeRightShortCommand() {
    if (activity.priority.isViewer) return null;
    if (activity.todo) return null;
    return StartThread(activity);
  }

  // Long right: Schedule (any thread)
  Command? _getSwipeRightLongCommand() {
    if (activity.priority.isViewer) return null;
    return PickScheduleThread(activity);
  }

  // Short left: Mark read (only if unread)
  Command? _getSwipeLeftShortCommand() {
    if (!activity.unread) return null;
    return MarkReadThread(activity);
  }

  // Long left: Finish (only if started/user-scheduled)
  Command? _getSwipeLeftLongCommand() {
    if (activity.priority.isViewer) return null;
    if (!activity.todo) return null;
    return FinishThread(activity, bump: bump, onBeforeRun: widget.onSwipeExit != null ? (_) async {} : null);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    // Get tag suggestions from PriorityBloc if available
    final tagSuggestions =
        buildContext.watch<PriorityBloc?>()?.state.tagSuggestions ?? [];

    final hasSubPriorityLabel =
        showSubPriority &&
        priorityContext != null &&
        activity.priority.id != priorityContext!.id;

    final hasEventTime =
        activity.at?.start != null &&
        !activity.at!.start!.toTimeOfDay().isMidnight;

    final isTodoBase = activity.todo && !activity.isLinkScheduleInstance;
    final isTimedEvent = showEventTiming && hasEventTime && !isTodoBase;

    final hasBodyLabel = hasSubPriorityLabel;

    final scheduleDate = () {
      // User-scheduled todos only show the label when a linked event provides
      // the date (e.g. a calendar event); plain todos hide it.
      if (isTodoBase && !activity.hasLinkSchedule) return null;
      if (showEventTiming && !isTodoBase) return null;
      if (activity.recurring) {
        final nextDate = activity.nextOccurrence(
          CustomBoundedDateRange(Date.today(), Date.today().addDays(365)),
        );
        if (nextDate != null) {
          final time =
              activity.at?.start?.toTimeOfDay() ??
              const TimeOfDay(hour: 0, minute: 0);
          return nextDate.toDateTime(time: time);
        }
        return activity.at?.start;
      }
      return activity.at?.start;
    }();

    final hasScheduleLabel = scheduleDate != null;
    final hasTopLabel = hasBodyLabel || hasScheduleLabel || isTimedEvent;

    // When a priority label is shown above the title row, compute its
    // rendered height + the 2px gap so we can push leading/trailing down
    // by the same amount, keeping them vertically centred with the title.
    final labelOffset = hasTopLabel
        ? (TextPainter(
            text: TextSpan(
              text: 'A',
              style: TextStyle(
                fontSize: buildContext.theme.typography.xs.fontSize,
                height: 1,
              ),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout()).height
        : 0.0;

    final threadColor = buildContext.colour.colours.fromTheme(
      activity.priority.displayColor,
    );
    final selectedBg = buildContext.colour.colours.backgroundFromTheme(
      activity.priority.displayColor,
    );

    final listTile = ListTile(
      command: CommandWrapper(ChangeCurrentThread(activity), icon: Value(null)),
      longPressCommand: isTouchDevice ? ShowThreadCommands(activity) : null,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: activity.displayTitle,
      subtitle: activity.preview,
      padding: EdgeInsets.only(
        right: buildContext.isMultiPanel
            ? buildContext.theme.spacing.lg + buildContext.theme.spacing.sm
            : buildContext.theme.buttonStyles.ghost.md.iconContentStyle.padding
                  .resolve(TextDirection.ltr)
                  .right,
      ),
      highlightColor: buildContext.colour.editableBackground,
      selectedColor: selectedBg,
      leadingBuilder: (isHovered, hasFocus) {
        final bool isTodo = activity.todo;
        final bool isScheduled = isTodo && activity.isFuture;

        // Icon 1: Calendar scheduling icon
        final schedDateTime =
            activity.on?.start?.toDateTime() ?? activity.at?.start;
        final schedLabel = isScheduled && schedDateTime != null
            ? 'Scheduled for ${formatRelativeSchedule(schedDateTime, buildContext)}'
            : 'Schedule';
        final calendarIcon = Button.icon(
          CommandWrapper(
            PickScheduleThread(activity),
            icon: Value(PlotIcon.schedule),
            title: schedLabel,
          ),
          selected: isScheduled,
          selectedColor: threadColor,
          color: isScheduled ? null : buildContext.theme.plotColors.veryMuted,
          hoverColor: isScheduled ? null : buildContext.colour.foreground,
          forceHover: isHovered,
        );

        // Icon 2: To-do state icon
        final Widget todoIcon;
        if (!isTodo) {
          todoIcon = Button.icon(
            CommandWrapper(
              StartThread(activity),
              icon: Value(PlotIcon.addTodo),
              title: 'Start',
            ),
            color: buildContext.theme.plotColors.veryMuted,
            hoverColor: buildContext.colour.foreground,
            forceHover: isHovered,
          );
        } else {
          final hasPending = activity.outstandingTasks;
          todoIcon = Button.icon(
            CommandWrapper(
              FinishThread(
                activity,
                bump: bump,
                onBeforeRun: widget.onDesktopFinish != null
                    ? (_) => widget.onDesktopFinish!()
                    : null,
              ),
              icon: Value(hasPending ? FontAwesomeIcons.circle : PlotIcon.todo),
              hoverIcon: hasPending
                  ? Value(FontAwesomeIcons.circleCheck)
                  : Value(PlotIcon.finish),
              title: 'Finish',
            ),
            selected: true,
            selectedColor: threadColor,
            forceHover: isHovered,
          );
        }

        final isWide = buildContext.isMultiPanel;
        final spacing = buildContext.theme.spacing;
        final ghostPad = buildContext
            .theme
            .buttonStyles
            .ghost
            .md
            .iconContentStyle
            .padding
            .resolve(TextDirection.ltr);

        // Left padding before first button; dot is overlaid centered
        // between x=0 and the first button's icon left edge.
        final leftPad = isWide ? spacing.lg : spacing.xl;
        final dotCenter = (leftPad + ghostPad.left) / 2;

        return Stack(
          children: [
            // Main content row: buttons — sizes the Stack
            Padding(
              padding: EdgeInsets.only(
                top: spacing.sm + labelOffset,
                bottom: spacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: leftPad),
                  if (isWide) calendarIcon,
                  todoIcon,
                  SizedBox(width: isWide ? spacing.lg : spacing.sm),
                ],
              ),
            ),
            // Notification dot centered between screen left and
            // the first button's icon left edge.
            Positioned(
              top: spacing.sm + labelOffset,
              bottom: spacing.sm,
              left: dotCenter - 3,
              width: 6,
              child: UnreadIndicator(
                color: activity.priority.displayColor,
                unread: activity.unread,
              ),
            ),
            // Time label for timed events, positioned at the top
            // to align with the body's header row. Right edge aligns
            // with the start button icon's right edge.
            if (isTimedEvent)
              Positioned(
                top: spacing.sm - 1,
                right: (isWide ? spacing.lg : spacing.sm) + ghostPad.right,
                child: Text(
                  isWide
                      ? activity.at!.start!.toTimeOfDay().formatShort(
                          buildContext,
                        )
                      : activity.at!.start!.toTimeOfDay().formatNarrow(
                          buildContext,
                        ),
                  style: TextStyle(
                    color: now
                        ? buildContext.colour.colours.fromTheme(
                            activity.priority.displayColor,
                          )
                        : buildContext.theme.colors.mutedForeground,
                    fontSize: buildContext.theme.typography.xs.fontSize,
                    height: 1,
                  ),
                ),
              ),
          ],
        );
      },
      bodyBuilder: (buildCtx, isHighlighted) {
        // State-dependent colors – only selection unmutes foreground;
        // hover should not change any foreground colors.
        final headerFg = selected ? threadColor : null;

        // Opaque composited bg for ThreadCommands gradient
        final compositedBg = selected
            ? selectedBg
            : isHighlighted
            ? buildContext.colour.editableBackground
            : buildContext.colour.background;

        return Padding(
          padding: EdgeInsets.only(
            top: buildContext.theme.spacing.sm,
            bottom: buildContext.theme.spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Narrow timed events: separate from Transform.translate
              // so only the priority label shifts left while timing
              // stays right-aligned with the gap header.
              if (isTimedEvent)
                Builder(
                  builder: (context) {
                    final veryMuted = context.theme.plotColors.veryMuted;
                    final hasDuration =
                        activity.at!.duration != null &&
                        activity.at!.duration!.inSeconds > 0;
                    final accentColor = buildContext.colour.colours.fromTheme(
                      activity.priority.displayColor,
                    );
                    final xsFontSize =
                        buildContext.theme.typography.xs.fontSize;
                    final currentTime = Time.now();

                    final rightParts = <Widget>[
                      if (activity.hasOtherAttendees)
                        _RsvpSummary(activity: activity),
                      // In-progress: elapsed ↑ · remaining ↓
                      if (now) ...[
                        if (activity.at!.start != null &&
                            currentTime
                                    .difference(activity.at!.start!)
                                    .inMinutes >=
                                1)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                Duration(
                                  minutes: currentTime
                                      .difference(activity.at!.start!)
                                      .inMinutes,
                                ).format(),
                                style: TextStyle(color: accentColor),
                              ),
                              SizedBox(width: buildContext.theme.spacing.xs),
                              FaIcon(
                                PlotIcon.up,
                                size: xsFontSize,
                                color: accentColor,
                              ),
                            ],
                          ),
                        if (activity.at!.end != null &&
                            activity.at!.end!.isAfter(currentTime))
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                Duration(
                                  minutes:
                                      (activity.at!.end!
                                                  .difference(currentTime)
                                                  .inSeconds /
                                              60)
                                          .ceil(),
                                ).format(),
                                style: TextStyle(color: accentColor),
                              ),
                              SizedBox(width: buildContext.theme.spacing.xs),
                              FaIcon(
                                PlotIcon.down,
                                size: xsFontSize,
                                color: accentColor,
                              ),
                            ],
                          ),
                      ] else if (isNext &&
                          activity.at!.start != null &&
                          activity.at!.start!.toDate() == Date.today()) ...[
                        // Next event: "in Xm" countdown
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FaIcon(
                              PlotIcon.schedule,
                              size: xsFontSize,
                              color: veryMuted,
                            ),
                            SizedBox(width: buildContext.theme.spacing.xs),
                            Text(
                              'in ${Duration(minutes: (activity.at!.start!.difference(currentTime).inSeconds / 60).ceil()).format()}',
                              style: TextStyle(color: veryMuted),
                            ),
                          ],
                        ),
                        if (hasDuration)
                          Text(
                            activity.at!.duration!.format(),
                            style: TextStyle(color: veryMuted),
                          ),
                      ] else ...[
                        if (hasDuration)
                          Text(
                            activity.at!.duration!.format(),
                            style: TextStyle(color: veryMuted),
                          ),
                      ],
                    ];

                    return DefaultTextStyle(
                      style: TextStyle(
                        color:
                            headerFg ??
                            buildContext.theme.colors.mutedForeground,
                        fontSize: buildContext.theme.typography.xs.fontSize,
                        height: 1,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: hasBodyLabel
                                ? PriorityLabel(
                                    priority: activity.priority,
                                    context: priorityContext,
                                    color: headerFg,
                                    fontSize:
                                        context.theme.typography.xs.fontSize,
                                    height: 1,
                                    muted: headerFg == null,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          for (int i = 0; i < rightParts.length; i++) ...[
                            if (i > 0)
                              Text(' · ', style: TextStyle(color: veryMuted)),
                            rightParts[i],
                          ],
                        ],
                      ),
                    );
                  },
                ),
              if (hasTopLabel && !isTimedEvent)
                DefaultTextStyle(
                  style: TextStyle(
                    color:
                        headerFg ?? buildContext.theme.colors.mutedForeground,
                    fontSize: buildContext.theme.typography.xs.fontSize,
                    height: 1,
                  ),
                  child: Builder(
                    builder: (context) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasBodyLabel)
                            Flexible(
                              child: PriorityLabel(
                                priority: activity.priority,
                                context: priorityContext,
                                color: headerFg,
                                fontSize: context.theme.typography.xs.fontSize,
                                height: 1,
                                muted: headerFg == null,
                              ),
                            ),
                          if (hasBodyLabel && hasScheduleLabel) Text(' · '),
                          if (scheduleDate != null) ...[
                            Text(formatRelativeSchedule(scheduleDate, context)),
                            if (activity.duration != null &&
                                activity.duration!.inSeconds > 0)
                              Text(' · ${activity.duration!.format()}'),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              // SizedBox + Stack keeps the title row height stable
              // regardless of whether ThreadCommands buttons are
              // visible. The fixed height matches FButton.icon (icon
              // size + icon-content padding) so it equals the leading
              // button area. This prevents layout shifts when
              // ThreadCommands appears on hover, and keeps the Stack
              // tall enough for buttons to receive hit-test events
              // (RenderBox.hitTest rejects positions outside its
              // size, so the Stack must be at least as tall as the
              // buttons for per-button hover to work).
              SizedBox(
                height:
                    buildContext.theme.iconSizes.base +
                    buildContext
                        .theme
                        .buttonStyles
                        .ghost
                        .md
                        .iconContentStyle
                        .padding
                        .resolve(TextDirection.ltr)
                        .vertical,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: _ThreadLogo(activity: activity),
                          ),
                          SizedBox(width: buildContext.theme.spacing.md),
                          Expanded(
                            child: Text.rich(
                              overflow: TextOverflow.ellipsis,
                              style: buildContext.theme.typography.md.copyWith(
                                color: buildContext.colour.foreground,
                              ),
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: activity.displayTitle,
                                    style: now
                                        ? TextStyle(
                                            color: buildContext.colour.colours
                                                .fromTheme(
                                                  activity
                                                      .priority
                                                      .displayColor,
                                                ),
                                          )
                                        : selected
                                        ? TextStyle(
                                            color:
                                                buildContext.colour.foreground,
                                          )
                                        : null,
                                  ),
                                  if (activity.preview != null &&
                                      activity.preview!.isNotEmpty &&
                                      activity.preview != activity.displayTitle)
                                    TextSpan(
                                      text: '  ${activity.preview}',
                                      style: TextStyle(
                                        color: buildContext.colour.muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ThreadCommands is overlaid via Positioned so it
                    // doesn't affect title row height. A gradient fade
                    // and solid background match the ListTile's
                    // effective background so the title text is cleanly
                    // truncated rather than bleeding through the buttons.
                    Positioned(
                      right: -buildContext
                          .theme
                          .buttonStyles
                          .ghost
                          .md
                          .iconContentStyle
                          .padding
                          .resolve(TextDirection.ltr)
                          .right,
                      top: 0,
                      bottom: 0,
                      child: Builder(
                        builder: (context) {
                          final tileBg = compositedBg;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 24,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      tileBg.withValues(alpha: 0),
                                      tileBg,
                                    ],
                                  ),
                                ),
                              ),
                              ColoredBox(
                                color: tileBg,
                                child: ThreadCommands(
                                  activity: activity,
                                  tagSuggestions: tagSuggestions,
                                  showCommands: isHighlighted,
                                  showEventTiming: showEventTiming,
                                  bump: bump,
                                  onDesktopFinish: widget.onDesktopFinish,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      selected: selected,
      focusNode: focusNode,
      onHover: onHover,
      reorderableIndex: reorderableIndex,
    );

    if (!activity.hasOtherAttendees) return listTile;

    return FTooltip(
      tipBuilder: (context, controller) {
        final contacts = activity.scheduleContacts;
        final attending = contacts.where((c) => c.status == 'attend').toList();
        final declined = contacts.where((c) => c.status == 'skip').toList();
        final noResponse = contacts
            .where((c) => c.status != 'attend' && c.status != 'skip')
            .toList();

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (attending.isNotEmpty) ...[
              Text(
                'Attending',
                style: context.theme.typography.sm.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              ...attending.map(
                (c) => Text(
                  c.contactName ?? c.contactEmail ?? 'Unknown',
                  style: context.theme.typography.sm,
                ),
              ),
            ],
            if (declined.isNotEmpty) ...[
              if (attending.isNotEmpty) const SizedBox(height: 4),
              Text(
                'Declined',
                style: context.theme.typography.sm.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              ...declined.map(
                (c) => Text(
                  c.contactName ?? c.contactEmail ?? 'Unknown',
                  style: context.theme.typography.sm,
                ),
              ),
            ],
            if (noResponse.isNotEmpty) ...[
              if (attending.isNotEmpty || declined.isNotEmpty)
                const SizedBox(height: 4),
              Text(
                'No response',
                style: context.theme.typography.sm.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              ...noResponse.map(
                (c) => Text(
                  c.contactName ?? c.contactEmail ?? 'Unknown',
                  style: context.theme.typography.sm,
                ),
              ),
            ],
          ],
        );
      },
      child: listTile,
    );
  }

  @override
  Widget build(BuildContext buildContext) {
    final isTouchDevice = !hasPhysicalKeyboard();
    final listTile = _buildListTile(buildContext, isTouchDevice);

    // Desktop: right-click context menu, no drag handle
    if (!isTouchDevice) {
      return ContextMenu(
        items: () => threadCommands(activity)
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
                onPress: () => buildContext.run(cmd),
              ),
            )
            .toList(),
        child: listTile,
      );
    }

    final swipeRightShort = _getSwipeRightShortCommand();
    final swipeRightLong = _getSwipeRightLongCommand();
    final swipeLeftShort = _getSwipeLeftShortCommand();
    final swipeLeftLong = _getSwipeLeftLongCommand();
    final hasSwipeCommands = swipeRightShort != null || swipeRightLong != null ||
        swipeLeftShort != null || swipeLeftLong != null;

    // Mobile with reorderable: trailing drag handle, swipeable only wraps content
    if (reorderableIndex != null) {
      final dragHandle = ReorderableDragStartListener(
        index: reorderableIndex!,
        child: Container(
          color: const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Icon(
            FontAwesomeIcons.gripDotsVertical,
            size: buildContext.theme.iconSizes.sm,
            color: buildContext.theme.plotColors.muted,
          ),
        ),
      );

      final content = hasSwipeCommands
          ? Swipeable(
              key: ValueKey(activity.id),
              startCommand: swipeRightShort,
              startLongCommand: swipeRightLong,
              endCommand: swipeLeftShort,
              endLongCommand: swipeLeftLong,
              exitOnActivation: widget.onSwipeExit,
              child: listTile,
            )
          : listTile;

      return Row(
        children: [
          Expanded(child: content),
          dragHandle,
        ],
      );
    }

    // Mobile without reorderable: wrap with swipeable if commands exist
    if (hasSwipeCommands) {
      return Swipeable(
        key: ValueKey(activity.id),
        startCommand: swipeRightShort,
        startLongCommand: swipeRightLong,
        endCommand: swipeLeftShort,
        endLongCommand: swipeLeftLong,
        exitOnActivation: widget.onSwipeExit,
        child: listTile,
      );
    }

    return listTile;
  }
}

class ThreadCommands extends HookWidget {
  const ThreadCommands({
    required this.activity,
    this.tagSuggestions = const [],
    this.showCommands = false,
    this.showEventTiming = false,
    this.bump = true,
    this.onDesktopFinish,
    super.key,
  });

  final Thread activity;
  final List<Tag> tagSuggestions;
  final bool showCommands;
  final bool showEventTiming;
  final bool bump;
  final Future<void> Function()? onDesktopFinish;

  @override
  Widget build(BuildContext context) {
    // Compute thread color for selected buttons
    final threadColor = context.colour.colours.fromTheme(
      activity.priority.displayColor,
    );

    // Get tags that this thread has
    // Exclude Tag.todo since it's shown as leading command
    // Exclude Tag.done for done threads since it's shown as leading icon
    final threadTags = useMemoized(
      () => Tag.getAll(
        onlyAddable: true,
      ).where((tag) => activity.hasTag(tag) && tag != Tag.todo).toList(),
      [activity.tags, activity.todo, activity.done],
    );

    // Create futures to load actor names for tooltips - memoized to avoid recreating on every build
    final tagFutures = useMemoized(
      () => threadTags.map((tag) async {
        final key = ValueKey(Object.hash(activity.id, tag.id));

        // Use FinishThread when clicking Tag.todo on a "todo" thread
        final command = tag == Tag.todo
            ? FinishThread(
                activity,
                stateIcon: true,
                bump: bump,
                onBeforeRun: onDesktopFinish != null
                    ? (_) => onDesktopFinish!()
                    : null,
              )
            : ToggleThreadTag(activity, tag);

        // Get actor names for tooltip
        final actorNames = await activity.getTagActorNames(tag);

        // Wrap command with subtitle showing actor names
        final wrappedCommand = actorNames.isNotEmpty
            ? CommandWrapper(command, subtitle: Value(actorNames))
            : command;

        final count = activity.tags[tag]?.length ?? 0;

        // Twist tags are display-only (not interactive)
        if (tag == Tag.twist) {
          return CountBadge(
            count: count,
            child: PulsingColorButton(key: key, primaryColor: threadColor),
          );
        }

        return CountBadge(
          count: count,
          child: Button.icon(
            wrappedCommand,
            key: key,
            selected: true,
            selectedColor: threadColor,
          ),
        );
      }).toList(),
      [activity.id, activity.tags],
    );

    // Get commands (only if showCommands is true)
    final isNarrow = !context.isMultiPanel;
    final hoverCommands = threadCommands(
      activity,
      skipPrimary: true,
      skipInfrequent: true,
      showEventTiming: showEventTiming,
    );
    final threadCommandButtons = showCommands
        ? [
            if (isNarrow) Button.icon(PickScheduleThread(activity)),
            ...hoverCommands
                .where((cmd) => !isNarrow || cmd is! PickScheduleThread)
                .map((cmd) => Button.icon(cmd)),
          ]
        : <Widget>[];

    // Conferencing/RSVP buttons only for threads shown by their own event
    // timing, not for user-scheduled todos.
    final isTodoBase = activity.todo && !activity.isLinkScheduleInstance;
    final showEventButtons = showEventTiming && !isTodoBase;

    final linksSnapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(activity.id), [activity.id]),
    );
    final conferencingActions = showEventButtons
        ? (linksSnapshot.data ?? [])
              .expand((link) => link.actions ?? <UserAction>[])
              .whereType<ConferencingUserAction>()
              .toList()
        : <ConferencingUserAction>[];

    // RSVP buttons (always visible for multi-attendee events)
    final rsvpButton = showEventButtons && activity.hasOtherAttendees
        ? Button.icon(ToggleRsvp(activity))
        : null;
    // Secondary skip button: appears on hover when no RSVP yet
    final skipSeriesButton =
        showEventButtons &&
            activity.hasOtherAttendees &&
            activity.currentUserRsvp == null
        ? Button.icon(SkipRsvpSeries(activity))
        : null;

    final tagSuggestionButtons = showCommands
        ? topThreadTags(
            activity,
            tagSuggestions,
          ).map((cmd) => Button.icon(cmd)).toList()
        : <Widget>[];

    // Build the final row with tags and commands
    return FutureBuilder<List<Widget>>(
      future: Future.wait(tagFutures),
      builder: (context, snapshot) {
        // While loading or on error, show buttons without subtitles
        final loadedTagButtons =
            snapshot.hasData && snapshot.connectionState == ConnectionState.done
            ? snapshot.data!
            : threadTags
                  .map((tag) {
                    final key = ValueKey(Object.hash(activity.id, tag.id));
                    final command = tag == Tag.todo
                        ? FinishThread(
                            activity,
                            stateIcon: true,
                            bump: bump,
                            onBeforeRun: onDesktopFinish != null
                                ? (_) => onDesktopFinish!()
                                : null,
                          )
                        : ToggleThreadTag(activity, tag);
                    final count = activity.tags[tag]?.length ?? 0;
                    // Twist tags are display-only (not interactive)
                    if (tag == Tag.twist) {
                      return CountBadge(
                        count: count,
                        child: PulsingColorButton(
                          key: key,
                          primaryColor: threadColor,
                        ),
                      );
                    }
                    return CountBadge(
                      count: count,
                      child: Button.icon(
                        command,
                        key: key,
                        selected: true,
                        selectedColor: threadColor,
                      ),
                    );
                  })
                  .take(5)
                  .toList();

        // Combine tags and commands with 6 button limit
        final List<Widget> allButtons;
        if (showCommands) {
          allButtons = [
            ...[
              ...threadCommandButtons,
              ...tagSuggestionButtons,
            ].take((5 - loadedTagButtons.length).clamp(0, 5)),
            // Always add ShowThreadCommands as the 6th button
            Button.icon(
              CommandWrapper(
                ShowThreadCommands(activity),
                icon: Value(PlotIcon.more),
              ),
            ),
            ...loadedTagButtons.take(5),
          ];
        } else {
          allButtons = loadedTagButtons;
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...allButtons,
            for (final action in conferencingActions)
              _ConferencingIconButton(action: action),
            if (showCommands && skipSeriesButton != null) skipSeriesButton,
            if (rsvpButton != null) rsvpButton,
          ],
        );
      },
    );
  }
}

class _ConferencingIconButton extends StatelessWidget {
  const _ConferencingIconButton({required this.action});

  final ConferencingUserAction action;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (action.provider) {
      ConferencingProvider.googleMeet => 'Join Google Meet',
      ConferencingProvider.zoom => 'Join on Zoom',
      ConferencingProvider.microsoftTeams => 'Join on Teams',
      ConferencingProvider.webex => 'Join Webex',
      ConferencingProvider.other => 'Join Meeting',
    };

    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: FButton.icon(
        variant: FButtonVariant.ghost,
        onPress: () {
          try {
            launchUrl(
              Uri.parse(action.url),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {}
        },
        child: Icon(PlotIcon.video, size: context.theme.iconSizes.base),
      ),
    );
  }
}

class _RsvpSummary extends StatelessWidget {
  const _RsvpSummary({required this.activity});

  final Thread activity;

  @override
  Widget build(BuildContext context) {
    final counts = activity.rsvpCounts;
    final attendColor = context.colour.colours.fromTheme(
      ThemeColor(0),
      muted: true,
    );
    final skipColor = context.colour.colours.fromTheme(
      ThemeColor(5),
      muted: true,
    );
    final undecidedColor = context.colour.veryMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 4,
      children: [
        if (counts.attend > 0)
          Text('${counts.attend}✓', style: TextStyle(color: attendColor)),
        if (counts.skip > 0)
          Text('${counts.skip}✗', style: TextStyle(color: skipColor)),
        if (counts.undecided > 0)
          Text('${counts.undecided}?', style: TextStyle(color: undecidedColor)),
      ],
    );
  }
}

class _ThreadLogo extends StatelessWidget {
  const _ThreadLogo({required this.activity});

  final Thread activity;

  bool get _isTappable =>
      ThreadSubType.fromIcon(activity.icon) != null || activity.icon == null;

  @override
  Widget build(BuildContext context) {
    final brightness = context.colour.brightness;
    final resolved = Thread.resolveIcon(
      activity.icon,
      prioritySharing: activity.priority.sharing,
    );
    final logoUrl = brightness == Brightness.dark
        ? (resolved.logoDarkUrl ?? resolved.logoUrl)
        : resolved.logoUrl;

    Widget icon;
    if (logoUrl != null && !LogoCache.isFailed(logoUrl)) {
      icon = Opacity(
        opacity: brightness == Brightness.dark ? 0.7 : 0.9,
        child: LogoImage(url: logoUrl),
      );
    } else {
      icon = Icon(
        resolved.fallbackIcon,
        size: 16,
        color: context.theme.plotColors.veryMuted,
      );
    }

    if (_isTappable && !activity.priority.isViewer) {
      return GestureDetector(
        onTap: () => context.run(ChangeThreadSubType(activity)),
        child: icon,
      );
    }
    return icon;
  }
}
