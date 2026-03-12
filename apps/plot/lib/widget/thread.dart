import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/util/hooks.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> _checkPendingItems(ThreadId threadId) async {
  final actorId = Base.actorId;

  // Check for notes assigned to current user
  final notes = await Note.getForThread(threadId);
  if (notes.any((n) => n.hasTag(Tag.todo, actorId))) return true;

  // Check for links assigned to user or unassigned, not already done
  final links = await Link.getForThread(threadId);
  for (final link in links) {
    if (link.assigneeId != null && link.assigneeId != actorId) continue;
    final doneStatuses =
        link.getTypeConfig()?.statuses?.where((s) => s.done) ?? [];
    if (doneStatuses.isEmpty) continue;
    if (!doneStatuses.any((s) => s.status == link.status)) return true;
  }

  return false;
}

class ThreadWidget extends StatelessWidget {
  const ThreadWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.now = false,
    this.showSubPriority = false,
    this.showEventTiming = false,
    this.bump = true,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    super.key,
  });

  final Thread activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final bool now;
  final bool showSubPriority;
  final bool showEventTiming;
  final bool bump;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  Command? _getSwipeRightCommand() {
    if (activity.priority.isViewer) return null;
    if (activity.at != null) return null;
    return activity.todo
        ? ThreadDone(activity, bump: bump)
        : ToggleThreadToDo(activity);
  }

  Command? _getSwipeLeftCommand() {
    if (activity.priority.isViewer) return null;
    if (activity.at != null) return null;
    return PickScheduleThread(activity);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    // Get tag suggestions from PriorityBloc if available
    final tagSuggestions =
        buildContext.watch<PriorityBloc?>()?.state.tagSuggestions ?? [];

    final hasSubPriorityLabel =
        showSubPriority &&
        context != null &&
        activity.priority.id != context!.id;

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
      title: activity.displayTitle,
      subtitle: activity.preview,
      padding: EdgeInsets.symmetric(horizontal: buildContext.contentPaddingH),
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
          color: isScheduled
              ? null
              : buildContext.theme.plotColors.veryMuted,
          forceHover: isHovered,
        );

        // Icon 2: To-do state icon
        final Widget todoIcon;
        if (!isTodo) {
          todoIcon = Button.icon(
            CommandWrapper(
              ThreadToDo(activity),
              icon: Value(PlotIcon.addTodo),
              title: 'Add to do',
            ),
            color: buildContext.theme.plotColors.muted,
            forceHover: isHovered,
          );
        } else {
          todoIcon = FutureBuilder<bool>(
            future: _checkPendingItems(activity.id),
            builder: (context, snapshot) {
              final hasPending = snapshot.data ?? false;
              return Button.icon(
                CommandWrapper(
                  ThreadDone(activity, bump: bump),
                  icon: Value(
                    hasPending ? FontAwesomeIcons.circle : PlotIcon.todo,
                  ),
                  hoverIcon: hasPending
                      ? Value(FontAwesomeIcons.circleCheck)
                      : const Value<IconData?>.absent(),
                  title: 'Done',
                ),
                selected: true,
                selectedColor: threadColor,
                forceHover: isHovered,
              );
            },
          );
        }

        return Stack(
          children: [
            Positioned(
              top: labelOffset,
              bottom: 0,
              left: (buildContext.theme.spacing.xl - 6) / 2,
              width: 6,
              child: UnreadIndicator(
                color: activity.priority.displayColor,
                unread: activity.unread,
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: buildContext.theme.spacing.sm + labelOffset,
                bottom: buildContext.theme.spacing.sm,
                left: buildContext.theme.spacing.xl - 7.5,
                right: buildContext.theme.spacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  calendarIcon,
                  todoIcon,
                ],
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
              if (hasTopLabel)
                DefaultTextStyle(
                  style: TextStyle(
                    color:
                        headerFg ?? buildContext.theme.colors.mutedForeground,
                    fontSize: buildContext.theme.typography.xs.fontSize,
                    height: 1,
                  ),
                  child: Builder(
                    builder: (context) {
                      final timingColor = now
                          ? TextStyle(
                              color: context.colour.colours.fromTheme(
                                activity.priority.displayColor,
                              ),
                            )
                          : null;

                      // For timed events, center time+duration across full tile width
                      if (isTimedEvent) {
                        final leadingIndent =
                            context.theme.iconSizes.base +
                            7.5 +
                            context.theme.spacing.sm;
                        final labelHeight = (TextPainter(
                          text: TextSpan(
                            text: 'A',
                            style: DefaultTextStyle.of(context).style,
                          ),
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                        )..layout()).height;

                        return SizedBox(
                          height: labelHeight,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              // Time text centered across full tile width
                              Positioned(
                                left: -leadingIndent,
                                right: 0,
                                top: 0,
                                bottom: 0,
                                child: Builder(
                                  builder: (context) {
                                    final timeStr = activity.at!.start!
                                        .toTimeOfDay()
                                        .formatShort(context);
                                    final hasDuration =
                                        activity.at!.duration != null &&
                                        activity.at!.duration!.inSeconds > 0;
                                    // [Expanded: digits right] [gap] [Expanded: am/pm left + duration right]
                                    final veryMuted =
                                        context.theme.plotColors.veryMuted;
                                    final spaceWidth = (TextPainter(
                                      text: TextSpan(
                                        text: ' ',
                                        style: DefaultTextStyle.of(
                                          context,
                                        ).style,
                                      ),
                                      maxLines: 1,
                                      textDirection: TextDirection.ltr,
                                    )..layout()).width;
                                    final amPmMatch = RegExp(
                                      r'[ap]m$',
                                    ).firstMatch(timeStr);
                                    final String leftText;
                                    final String? rightText;
                                    if (amPmMatch != null) {
                                      leftText = timeStr
                                          .substring(0, amPmMatch.start)
                                          .trimRight();
                                      rightText = timeStr.substring(
                                        amPmMatch.start,
                                      );
                                    } else {
                                      leftText = timeStr;
                                      rightText = null;
                                    }
                                    return Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            leftText,
                                            style: timingColor,
                                            textAlign: TextAlign.right,
                                          ),
                                        ),
                                        SizedBox(width: spaceWidth),
                                        Expanded(
                                          child: Row(
                                            children: [
                                              if (rightText != null)
                                                Text(
                                                  rightText,
                                                  style: timingColor,
                                                ),
                                              const Spacer(),
                                              if (activity.hasOtherAttendees)
                                                _RsvpSummary(
                                                  activity: activity,
                                                  color: veryMuted,
                                                ),
                                              if (activity.hasOtherAttendees &&
                                                  hasDuration)
                                                const SizedBox(width: 4),
                                              if (hasDuration)
                                                Text(
                                                  activity.at!.duration!
                                                      .format(),
                                                  style: TextStyle(
                                                    color: veryMuted,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              // Priority label on the left
                              if (hasBodyLabel)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: PriorityLabel(
                                    priority: activity.priority,
                                    context: this.context,
                                    color: headerFg,
                                    fontSize:
                                        context.theme.typography.xs.fontSize,
                                    height: 1,
                                    muted: headerFg == null,
                                  ),
                                ),
                            ],
                          ),
                        );
                      }

                      // Non-timed: left-aligned Row
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasBodyLabel)
                            Flexible(
                              child: PriorityLabel(
                                priority: activity.priority,
                                context: this.context,
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
                        .iconContentStyle
                        .padding
                        .resolve(TextDirection.ltr)
                        .vertical,
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          _LinkLogos(threadId: activity.id),
                          Expanded(
                            child: Text.rich(
                              overflow: TextOverflow.ellipsis,
                              style: buildContext.theme.typography.base
                                  .copyWith(
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
                      right: 0,
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

    final swipeRightCommand = _getSwipeRightCommand();
    final swipeLeftCommand = _getSwipeLeftCommand();
    final hasSwipeCommands =
        swipeRightCommand != null || swipeLeftCommand != null;

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
              startCommand: swipeRightCommand,
              endCommand: swipeLeftCommand,
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
        startCommand: swipeRightCommand,
        endCommand: swipeLeftCommand,
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
    super.key,
  });

  final Thread activity;
  final List<Tag> tagSuggestions;
  final bool showCommands;
  final bool showEventTiming;
  final bool bump;

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
            ? ThreadDone(activity, stateIcon: true, bump: bump)
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
    final threadCommandButtons = showCommands
        ? threadCommands(
            activity,
            skipPrimary: true,
            skipInfrequent: true,
            showEventTiming: showEventTiming,
          ).map((cmd) => Button.icon(cmd)).toList()
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
                        ? ThreadDone(activity, stateIcon: true, bump: bump)
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
        style: FButtonStyle.ghost(),
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
  const _RsvpSummary({required this.activity, required this.color});

  final Thread activity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final counts = activity.rsvpCounts;
    final style = TextStyle(color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: 4,
      children: [
        if (counts.attend > 0) Text('${counts.attend}✓', style: style),
        if (counts.skip > 0) Text('${counts.skip}✗', style: style),
        if (counts.undecided > 0) Text('${counts.undecided}?', style: style),
      ],
    );
  }
}

class _LinkLogos extends HookWidget {
  const _LinkLogos({required this.threadId});

  /// Cache of logo URLs by (threadId, brightness) so stream restarts during
  /// reorder don't flash empty for a frame.
  static final Map<(ThreadId, Brightness), List<String>> _logoCache = {};

  final ThreadId threadId;

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.platformBrightnessOf(context);
    final links = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(threadId), [threadId]),
    );
    final cacheKey = (threadId, brightness);
    final List<String> logos;
    if (links.data != null) {
      logos = links.data!
          .map((Link l) => l.logoForBrightness(brightness))
          .whereType<String>()
          .where((url) => url.isNotEmpty && !LogoCache.isFailed(url))
          .toSet()
          .toList();
      _logoCache[cacheKey] = logos;
    } else {
      logos = _logoCache[cacheKey] ?? <String>[];
    }
    if (logos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(right: context.theme.spacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: logos.map((String logo) => LogoImage(url: logo)).toList(),
      ),
    );
  }
}
