import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/logo_cache.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/theme.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/util/shortcut.dart';
import 'package:url_launcher/url_launcher.dart';

class ThreadWidget extends StatefulWidget {
  const ThreadWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.now = false,
    this.isNext = false,
    this.isAssociated = false,
    this.isOutsidePriority = false,
    this.showSubPriority = false,
    this.showEventTiming = false,
    this.bump = true,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.onSwipeExit,
    this.onDesktopFinish,
    this.onMobileFinish,
    super.key,
  });

  final Thread activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final bool now;
  final bool isNext;
  final bool isAssociated;

  /// Whether this thread is from a priority outside the current context.
  /// Outside-priority link-scheduled events are dimmed in the UI.
  final bool isOutsidePriority;
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

  /// Called before a finish command runs on mobile (toggle tap path).
  /// Should trigger collapse-only removal animation.
  final Future<void> Function()? onMobileFinish;

  @override
  State<ThreadWidget> createState() => _ThreadWidgetState();
}

class _ThreadWidgetState extends State<ThreadWidget> {
  bool _leadingHovered = false;
  bool _rowHovered = false;
  BlockDragController? _dragController;

  /// True while a block-level drag is in progress anywhere in the agenda.
  /// Threads are not drop targets for block drags — suppressing the hover
  /// effect prevents the row from looking like one.
  bool get _isBlockDragging => _dragController?.isDragging ?? false;

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
  void dispose() {
    _dragController?.removeListener(_onDragChanged);
    super.dispose();
  }

  void _onDragChanged() {
    if (!mounted) return;
    setState(() {});
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

  // Short right: Add to today. Universal "deal with this now" — works on
  // unscheduled threads (adds them to today), future-scheduled threads
  // (bumps to today), and already-today threads (no-op re-save).
  Command? _getSwipeRightShortCommand() {
    if (widget.isOutsidePriority) return null;
    if (activity.priority.isViewer) return null;
    return StartThread(activity);
  }

  // Long right: Schedule for another day.
  Command? _getSwipeRightLongCommand() {
    if (widget.isOutsidePriority) return null;
    if (activity.priority.isViewer) return null;
    return PickScheduleThread(activity);
  }

  // Short left: Finish (only for scheduled/todo threads — inert on
  // unscheduled threads, the user must reach the long zone for the menu).
  Command? _getSwipeLeftShortCommand() {
    if (widget.isOutsidePriority) return null;
    if (activity.priority.isViewer) return null;
    if (!activity.todo) return null;
    return FinishThread(
      activity,
      bump: bump,
      // Link schedule instances stay visible after finish, so skip removal
      // animation. For swipe, the non-link-schedule path uses an empty
      // callback so onSwipeExit handles the visual removal instead.
      onBeforeRun: activity.isLinkScheduleInstance
          ? null
          : widget.onSwipeExit != null
          ? (_) async {}
          : null,
    );
  }

  // Long left: Menu. Universal across all list views. Mark read and the
  // other less-frequent actions are accessible from here.
  Command? _getSwipeLeftLongCommand() {
    if (widget.isOutsidePriority) return null;
    return ShowThreadCommands(activity);
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

    final hasBodyLabel = hasSubPriorityLabel;

    final scheduleDate = () {
      // User-scheduled todos only show the label when a linked event provides
      // the date (e.g. a calendar event); plain todos hide it.
      if (isTodoBase && !activity.hasLinkSchedule) return null;
      // Events with their own start time never show a schedule label here;
      // the agenda's AgendaTile carries the time and the activity feed
      // shows it via the priority-hover row below.
      if (!isTodoBase && hasEventTime) return null;
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
    final hasTopLabel = hasBodyLabel || hasScheduleLabel;

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
      // Bypass ListTile's run() spinner tracking. The command returns
      // CommandDone immediately (navigation is fire-and-forget), but routing
      // it through context.run directly keeps the spinner machinery out of
      // the hot tap path entirely.
      onTap: () {
        buildContext.run(ChangeCurrentThread(activity));
      },
      // Menu opens via long-left swipe on touch (see Swipeable wrapper
      // below) and via right-click on desktop (see ContextMenu wrapper
      // below). Long-press is reserved for starting a reorder drag.
      longPressCommand: null,
      crossAxisAlignment: CrossAxisAlignment.start,
      title: activity.displayTitle,
      subtitle: activity.displayPreview,
      padding: EdgeInsets.only(
        right: buildContext.isMultiPanel
            ? buildContext.theme.spacing.lg
            : buildContext.theme.buttonStyles.ghost.md.iconContentStyle.padding
                  .resolve(TextDirection.ltr)
                  .right,
      ),
      highlightColor: buildContext.colour.editableBackground,
      selectedColor: selectedBg,
      // While a block drag is in progress, threads are not drop targets —
      // suppress the bg highlight so the row doesn't read as one.
      noHoverHighlight: _isBlockDragging,
      leadingBuilder: (rawHovered, hasFocus) {
        final isHovered = _isBlockDragging ? false : rawHovered;
        final leadingHovered = _isBlockDragging ? false : _leadingHovered;
        final bool isTodo = activity.todo;

        // Leading button: to-do state icon (shows calendar icon when scheduled)
        final longPress = activity.priority.isViewer
            ? null
            : () => buildContext.run(PickScheduleThread(activity));

        // The command that the leading tap target triggers.
        // Associated threads use the same leading commands as regular
        // (non-event) threads — adding to the agenda or finishing —
        // because users still want to manage the thread's own todo
        // state from this slot. Removing the thread from the event is
        // surfaced as an X-icon at the trailing end on hover instead.
        final Command leadingCommand;
        if (!isTodo) {
          leadingCommand = StartThread(activity);
        } else {
          leadingCommand = FinishThread(
            activity,
            bump: bump,
            // Link schedule instances must stay visible after finish (only the
            // base todo duplicate is removed), so skip the removal animation.
            onBeforeRun: activity.isLinkScheduleInstance
                ? null
                : widget.onMobileFinish != null
                ? (_) => widget.onMobileFinish!()
                : widget.onDesktopFinish != null
                ? (_) => widget.onDesktopFinish!()
                : null,
          );
        }

        // Leading column hugs a centred icon with horizontal padding that
        // matches the trailing edge of the row: roomy on desktop, tight on
        // mobile. The threads-in-agenda layout that needed an agenda-time-
        // width gutter is no longer used here.
        final iconBaseSize = buildContext.theme.iconSizes.base;
        final leadingPad = buildContext.isMultiPanel
            ? buildContext.theme.spacing.lg
            : buildContext.theme.buttonStyles.ghost.md.iconContentStyle.padding
                  .resolve(TextDirection.ltr)
                  .right;
        final leadingW = iconBaseSize + leadingPad * 2;
        final spacing = buildContext.theme.spacing;

        final Widget todoIcon;
        final String leadingTitle = !isTodo ? 'Do today' : 'Finish';
        final iconHoverColor = leadingHovered
            ? buildContext.colour.foreground
            : buildContext.colour.muted;
        if (!isTodo) {
          todoIcon = Button.icon(
            _ThreadLeadingCommand(
              leadingCommand,
              outlineIcon: PlotIcon.todo,
              filledIcon: PlotIcon.todoFilled,
              showEmpty: !activity.unread,
              dotColor: activity.unread
                  ? buildContext.colour.accent.withValues(alpha: 0.7)
                  : null,
              iconHoverColor: iconHoverColor,
              hoverIcon: Value(PlotIcon.todo),
              title: leadingTitle,
            ),
            forceHover: isHovered,
            onLongPress: longPress,
          );
        } else {
          // Active and scheduled threads both use the circle; hover swaps to
          // a circle-with-check finish affordance.
          todoIcon = Button.icon(
            _ThreadLeadingCommand(
              leadingCommand,
              outlineIcon: FontAwesomeIcons.circle,
              filledIcon: FontAwesomeIcons.solidCircle,
              showFill: activity.unread,
              iconHoverColor: iconHoverColor,
              hoverIcon: Value(FontAwesomeIcons.circleCheck),
              title: leadingTitle,
            ),
            selected: true,
            selectedColor: threadColor,
            forceHover: isHovered,
            onLongPress: longPress,
          );
        }

        return SizedBox(
          width: leadingW,
          child: Padding(
            padding: EdgeInsets.only(
              top: spacing.sm + labelOffset,
              bottom: spacing.sm,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Full-area tap/hover target
                Positioned.fill(
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _leadingHovered = true),
                    onExit: (_) => setState(() => _leadingHovered = false),
                    child: FTooltip(
                      tipBuilder: (context, controller) => Text(leadingTitle),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => buildContext.run(leadingCommand),
                        onLongPress: longPress,
                      ),
                    ),
                  ),
                ),
                // Centered icon (visual only)
                Center(child: IgnorePointer(child: todoIcon)),
              ],
            ),
          ),
        );
      },
      bodyBuilder: (buildCtx, rawHighlighted) {
        // While a block drag is in progress, treat the thread as not
        // highlighted so it doesn't render edit affordances or the
        // ThreadCommands row that would make it look like a drop target.
        final isHighlighted = _isBlockDragging ? false : rawHighlighted;
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
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasBodyLabel)
                            Flexible(
                              child: _PriorityHoverArea(
                                activity: activity,
                                priorityContext: priorityContext,
                                headerFg: headerFg,
                                fontSize: context.theme.typography.xs.fontSize,
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
                            child:
                                isHighlighted &&
                                    !activity.priority.isViewer &&
                                    !widget.isOutsidePriority
                                ? _EditHoverIcon(activity: activity)
                                : _ThreadLogo(activity: activity),
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
                                  if (activity.displayPreview != null &&
                                      activity.displayPreview!.isNotEmpty &&
                                      activity.displayPreview !=
                                          activity.displayTitle)
                                    TextSpan(
                                      text: '  ${activity.displayPreview}',
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
                      // Push the trailing row right enough that its icon
                      // glyphs / avatars line up with the right edge of
                      // header durations (block headers end at
                      // `spacing.lg` from the agenda edge — same as the
                      // ListTile's right padding — so we offset by the
                      // button's own internal icon padding to land the
                      // visible glyph/avatar right at that boundary).
                      right:
                          -buildContext
                              .theme
                              .buttonStyles
                              .ghost
                              .md
                              .iconContentStyle
                              .padding
                              .resolve(TextDirection.ltr)
                              .right -
                          buildContext.theme.spacing.xs,
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
                                  isAssociated: widget.isAssociated,
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

    return listTile;
  }

  @override
  Widget build(BuildContext buildContext) {
    final isTouchDevice = !hasPhysicalKeyboard();
    final rawListTile = _buildListTile(buildContext, isTouchDevice);

    // Dim outside-priority threads (cross-priority calendar events).
    // Remove dimming on hover so the user can read the full content.
    // While a block drag is active, ignore hover so the row doesn't
    // light up like a drop target.
    final rowHovered = _rowHovered && !_isBlockDragging;
    final listTile = widget.isOutsidePriority
        ? MouseRegion(
            onEnter: (_) => setState(() => _rowHovered = true),
            onExit: (_) => setState(() => _rowHovered = false),
            child: Opacity(
              opacity: rowHovered ? 1.0 : 0.4,
              child: rawListTile,
            ),
          )
        : rawListTile;

    // Desktop: right-click context menu, no drag handle
    if (!isTouchDevice) {
      // Capture the bloc here so commands like Archive can fire their
      // optimistic update even when dispatched from a context that has
      // shed the priority page tree.
      final priorityBloc = buildContext.read<PriorityBloc?>();
      return ContextMenu(
        items: (close) => threadCommands(activity, priorityBloc: priorityBloc)
            .map(
              (cmd) => FItem(
                title: Text(cmd.title),
                prefix: cmd.icon != null ? Icon(cmd.icon, size: 16) : null,
                onPress: () {
                  close();
                  buildContext.run(cmd);
                },
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
    final hasSwipeCommands =
        swipeRightShort != null ||
        swipeRightLong != null ||
        swipeLeftShort != null ||
        swipeLeftLong != null;

    // Mobile: long-press on the row starts a reorder drag (handled by the
    // enclosing block-drag or ReorderableDelayedDragStartListener); swipes
    // expose the quick actions and the menu.
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
    this.isAssociated = false,
    this.onDesktopFinish,
    this.onMobileFinish,
    super.key,
  });

  final Thread activity;
  final List<Tag> tagSuggestions;
  final bool showCommands;
  final bool showEventTiming;
  final bool bump;

  /// True when this thread is rendered nested under an event header in
  /// the agenda. When set and [showCommands] is true, a "Remove from
  /// event" X-icon is appended to the trailing-most position so the
  /// user can detach the thread from the event without disturbing its
  /// own todo state.
  final bool isAssociated;
  final Future<void> Function()? onDesktopFinish;
  final Future<void> Function()? onMobileFinish;

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
                onBeforeRun: activity.isLinkScheduleInstance
                    ? null
                    : onMobileFinish != null
                    ? (_) => onMobileFinish!()
                    : onDesktopFinish != null
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

        final count = TagActors.countOf(activity.tags[tag]);

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

    // Get commands (only if showCommands is true).
    // Share affordance lives in the trailing slot (as an [AvatarGroup]) when
    // the thread is shared, so we drop it from the hover-command pool to
    // avoid duplication. When the thread isn't shared yet, we surface a
    // share button after the more-commands menu so the affordance stays
    // visible without competing with tag buttons for the take() limit.
    final isShared = isThreadShared(activity);
    final rawHoverCommands = threadCommands(
      activity,
      skipPrimary: true,
      skipInfrequent: true,
      showEventTiming: showEventTiming,
    ).toList();
    // PickScheduleThread is surfaced via the thread-icon hover swap, so
    // exclude it from the trailing command row to avoid duplication.
    // PickThreadShared is rendered separately (see [trailingShareButton])
    // when the thread isn't shared.
    final hoverCommands = rawHoverCommands.where(
      (cmd) => cmd is! PickScheduleThread && cmd is! PickThreadShared,
    );
    final threadCommandButtons = showCommands
        ? hoverCommands.map((cmd) => Button.icon(cmd)).toList()
        : <Widget>[];

    // When the thread isn't shared, render the share command as an icon
    // button anchored after the more-commands menu — the trailing
    // AvatarGroup slot is reserved for the avatars of shared threads.
    final trailingShareButton = !isShared && showCommands
        ? Button.icon(PickThreadShared(activity))
        : null;

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

    // RSVP buttons for calendar events (link schedule instances).
    // When the user has been invited to an event and hasn't responded,
    // show explicit Attend + Skip buttons side-by-side. Otherwise show
    // the single ToggleRsvp button (solo events, or already-RSVP'd events).
    final isCalendarEvent = showEventButtons && activity.isLinkScheduleInstance;
    final needsRsvp =
        isCalendarEvent &&
        activity.currentUserRsvp == null &&
        activity.hasOtherAttendees;
    final attendButton = needsRsvp ? Button.icon(AttendRsvp(activity)) : null;
    final skipButton = needsRsvp ? Button.icon(SkipRsvp(activity)) : null;
    final rsvpButton = isCalendarEvent && !needsRsvp
        ? Button.icon(ToggleRsvp(activity))
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
                            onBeforeRun: activity.isLinkScheduleInstance
                                ? null
                                : onMobileFinish != null
                                ? (_) => onMobileFinish!()
                                : onDesktopFinish != null
                                ? (_) => onDesktopFinish!()
                                : null,
                          )
                        : ToggleThreadTag(activity, tag);
                    final count = TagActors.countOf(activity.tags[tag]);
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
            // When the thread isn't shared, the share affordance sits to
            // the right of the more-commands menu so it's always visible.
            if (trailingShareButton != null) trailingShareButton,
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
            if (attendButton != null) attendButton,
            if (skipButton != null) skipButton,
            if (rsvpButton != null) rsvpButton,
            // Trailing AvatarGroup slot — only present when the thread is
            // actually shared. When not shared we leave the slot empty (no
            // padding, no tooltip); the share command is reachable via the
            // hover commands list instead.
            if (isShared) SharedCommandButton(thread: activity),
            // Trailing-most "Remove from event" X-icon for associated
            // threads, surfaced only on hover. The row is positioned at
            // the right edge with mainAxisSize.min, so adding this as
            // the last child pushes existing trailing items (tags,
            // avatars) to the left.
            if (isAssociated && showCommands)
              Button.icon(DisassociateThread(activity)),
          ],
        );
      },
    );
  }
}

/// Renders the "Share" / "Shared" command. When the thread is shared, the
/// button hugs an [AvatarGroup] so the avatars sit at the row's natural
/// height. When the thread is not yet shared, it shows the share icon at the
/// same visual weight so the share affordance stays visible — callers that
/// don't want an empty-state icon (e.g. [ThreadCommands], which surfaces the
/// share command via hover commands instead) should gate this widget on
/// `isThreadShared(thread)`.
class SharedCommandButton extends HookWidget {
  const SharedCommandButton({required this.thread, super.key});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final command = PickThreadShared(thread);
    final shared = isThreadShared(thread);

    // Expand the avatar circle into the button's icon padding so the
    // initials are legible while the button's overall height still matches
    // neighbouring icon buttons (icon + padding == avatar + zero padding).
    // Use `iconSizes.base` as the baseline because Plot's `Button.icon`
    // wraps icons in a `SizedBox(height: iconSizes.base)` regardless of
    // forui's `iconContentStyle.iconStyle.size` (which is `lg`); using `lg`
    // here makes the avatar 2px taller than sibling buttons and grows the
    // surrounding row height.
    final iconContentStyle =
        context.theme.buttonStyles.ghost.md.iconContentStyle;
    final iconPadding = iconContentStyle.padding.resolve(TextDirection.ltr);
    final iconSize = context.theme.iconSizes.base;
    final avatarSize = iconSize + iconPadding.top + iconPadding.bottom;

    // The synchronous `sharedDisplayActors` getter only returns actors
    // already in the in-memory cache. On first render in the agenda the
    // contacts haven't been fetched yet, so it returns an empty list and
    // the avatar group renders nothing. Kick off an async resolve so the
    // cache fills; once it does, this widget rebuilds with the resolved
    // actors AND any other ThreadWidget sharing the same contacts gets a
    // cache hit on its next build.
    final contactsKey = thread.contacts.map((u) => u.toString()).join('|');
    final loadedActors = useFuture(
      useMemoized(() => command.loadSharedDisplayActors(), [contactsKey]),
    ).data;
    final actors = loadedActors ?? command.sharedDisplayActors;

    // Surface RSVP info in the unified avatar tooltip when the thread is a
    // calendar event with other invitees. Otherwise the tooltip falls back
    // to plain actor names.
    final scheduleContacts = thread.hasOtherAttendees
        ? thread.scheduleContacts
        : null;

    final Widget child = shared
        ? AvatarGroup(
            actors: actors,
            totalCount: command.sharedTotalCount,
            size: avatarSize,
            scheduleContacts: scheduleContacts,
          )
        : SizedBox(
            width: iconSize,
            height: iconSize,
            child: Center(
              child: FaIcon(command.icon ?? PlotIcon.shareAdd, size: iconSize),
            ),
          );

    final button = FButton.icon(
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(999)),
          ),
        ]),
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          // Keep horizontal padding so this button hugs the row edge the
          // same way as sibling icon buttons; zero vertical so the avatar
          // fills the full button height.
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(horizontal: iconPadding.left),
          ),
          // Drop the default minWidth (36) so the button hugs the avatar
          // group's natural width — narrower groups (1–2 avatars) shouldn't
          // get padded out to the size of a 3-slot group. Keep minHeight so
          // vertical alignment with sibling icon buttons is preserved.
          constraints: BoxConstraints(
            minHeight: iconContentStyle.constraints.minHeight,
          ),
        ),
      ),
      variant: FButtonVariant.ghost,
      onPress: () => context.run(command),
      child: child,
    );

    // When shared, the AvatarGroup renders its own unified tooltip listing
    // contacts (with RSVP icons when applicable) — a generic "Shared" tooltip
    // would shadow it. Keep the title tooltip only for the unshared share
    // icon state.
    if (shared) return button;
    return FTooltip(
      tipBuilder: (context, controller) => Text(command.title),
      child: button,
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

class RsvpSummary extends StatelessWidget {
  const RsvpSummary({required this.activity, this.fontSize, super.key});

  final Thread activity;
  final double? fontSize;

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
          Text(
            '${counts.attend}✓',
            style: TextStyle(
              color: attendColor,
              fontSize: fontSize,
              height: 1,
            ),
          ),
        if (counts.skip > 0)
          Text(
            '${counts.skip}✗',
            style: TextStyle(color: skipColor, fontSize: fontSize, height: 1),
          ),
        if (counts.undecided > 0)
          Text(
            '${counts.undecided}?',
            style: TextStyle(
              color: undecidedColor,
              fontSize: fontSize,
              height: 1,
            ),
          ),
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
    final resolved = Thread.resolveIcon(activity.icon);
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

class _ThreadLeadingCommand extends CommandWrapper {
  final IconData outlineIcon;
  final IconData filledIcon;
  final bool showFill;
  final bool showEmpty;
  final Color? dotColor;
  final Color? iconHoverColor;

  _ThreadLeadingCommand(
    super.command, {
    required this.outlineIcon,
    required this.filledIcon,
    this.showFill = false,
    this.showEmpty = false,
    this.dotColor,
    this.iconHoverColor,
    super.hoverIcon,
    super.title,
  }) : super(icon: Value(outlineIcon));

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final baseSize = context.theme.iconSizes.base;
    if (hoverIcon) {
      // Apply foreground color directly since IgnorePointer prevents
      // FButton from detecting its own hover state.
      if (iconHoverColor != null) {
        return Icon(
          this.hoverIcon ?? outlineIcon,
          size: baseSize,
          color: iconHoverColor,
        );
      }
      return null;
    }
    if (showFill) {
      final isDark = context.read<ThemeBloc>().isDarkMode(context);
      return SizedBox(
        width: baseSize,
        height: baseSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: isDark ? 0.55 : 0.2,
              child: Icon(filledIcon, size: baseSize),
            ),
            Icon(outlineIcon, size: baseSize),
          ],
        ),
      );
    }
    if (dotColor != null) {
      return SizedBox(
        width: baseSize,
        height: baseSize,
        child: Center(
          child: CustomPaint(
            size: const Size.square(6),
            painter: _DotPainter(color: dotColor!),
          ),
        ),
      );
    }
    if (showEmpty) {
      return SizedBox(width: baseSize, height: baseSize);
    }
    return null;
  }
}

/// Replaces the small thread logo when the row is hovered, surfacing the
/// edit-thread action without crowding the trailing command row.
class _EditHoverIcon extends StatefulWidget {
  const _EditHoverIcon({required this.activity});

  final Thread activity;

  @override
  State<_EditHoverIcon> createState() => _EditHoverIconState();
}

class _EditHoverIconState extends State<_EditHoverIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final command = EditThread(widget.activity);
    final iconData = FontAwesomeIcons.pen;
    final shortcutText = hasPhysicalKeyboard() && command.shortcut != null
        ? formatShortcut(command.shortcut)
        : '';
    return FTooltip(
      tipBuilder: (ctx, controller) {
        if (shortcutText.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(command.title),
              Text(
                shortcutText,
                style: ctx.theme.typography.xs.copyWith(
                  color: ctx.theme.colors.mutedForeground,
                ),
              ),
            ],
          );
        }
        return Text(command.title);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.run(command),
          onLongPress: () =>
              context.run(MoveThreadToPriority(widget.activity)),
          child: Center(
            child: FaIcon(
              iconData,
              size: 14,
              color: _hovered ? context.colour.foreground : context.colour.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the priority label in the top-of-row meta strip with a hover state
/// and a trailing veryMuted select icon. Hover unmutes the label and tints
/// the select icon with the accent colour; clicking anywhere in the area
/// opens the move modal.
class _PriorityHoverArea extends StatefulWidget {
  const _PriorityHoverArea({
    required this.activity,
    required this.priorityContext,
    required this.headerFg,
    required this.fontSize,
  });

  final Thread activity;
  final Priority? priorityContext;
  final Color? headerFg;
  final double? fontSize;

  @override
  State<_PriorityHoverArea> createState() => _PriorityHoverAreaState();
}

class _PriorityHoverAreaState extends State<_PriorityHoverArea> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final command = MoveThreadToPriority(widget.activity);
    final shortcutText = hasPhysicalKeyboard() && command.shortcut != null
        ? formatShortcut(command.shortcut)
        : '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: FTooltip(
        tipBuilder: (ctx, controller) {
          if (shortcutText.isNotEmpty) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(command.title),
                Text(
                  shortcutText,
                  style: ctx.theme.typography.xs.copyWith(
                    color: ctx.theme.colors.mutedForeground,
                  ),
                ),
              ],
            );
          }
          return Text(command.title);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.run(command),
          child: PriorityLabel(
            priority: widget.activity.priority,
            context: widget.priorityContext,
            color: widget.headerFg,
            fontSize: widget.fontSize,
            height: 1,
            muted: widget.headerFg == null && !_hovered,
            onSelect: (_) => context.run(command),
          ),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => color != oldDelegate.color;
}
