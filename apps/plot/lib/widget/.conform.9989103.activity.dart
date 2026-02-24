import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/initials.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/hooks.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.now = false,
    this.showSubPriority = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    super.key,
  });

  final Activity activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final bool now;
  final bool showSubPriority;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  Command? _getSwipeRightCommand() {
    if (activity.type == ActivityType.event) return null;
    return activity.doNow ? FinishAction(activity) : ToggleAction(activity);
  }

  Command? _getSwipeLeftCommand() {
    if (activity.type == ActivityType.event) return null;
    return PickScheduleActivity(activity);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    // Get tag suggestions from PriorityBloc if available
    final tagSuggestions =
        buildContext.watch<PriorityBloc?>()?.state.tagSuggestions ?? [];

    final hasSubPriorityLabel =
        showSubPriority &&
        context != null &&
        activity.priority.id != context!.id;

    // Compute top padding to align leading/trailing with the title, not the
    // full body.  The Row uses CrossAxisAlignment.center, so adding top
    // padding P shifts a child down by P/2.  We need a shift of
    // (labelHeight + gap) / 2, hence P = labelHeight + gap.
    final double labelOffset;
    if (hasSubPriorityLabel) {
      final xsFontSize = buildContext.theme.typography.xs.fontSize ?? 12.0;
      final xsLineHeight = buildContext.theme.typography.xs.height ?? 1.2;
      labelOffset = xsFontSize * xsLineHeight + 2.0;
    } else {
      labelOffset = 0.0;
    }

    return ListTile(
      command: CommandWrapper(
        ChangeCurrentActivity(activity),
        icon: Value(null),
      ),
      longPressCommand: isTouchDevice ? ShowActivityCommands(activity) : null,
      title: activity.displayTitle,
      subtitle: activity.preview,
      padding: EdgeInsets.symmetric(horizontal: buildContext.theme.spacing.xl),
      leadingBuilder: (isHovered, hasFocus) {
        final activityColor = buildContext.colour.colours.fromTheme(
          activity.priority.displayColor,
        );
        return Stack(
          children: [
            Positioned(
              top: 0,
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
                top: labelOffset,
                // Subtract FButton.icon's internal padding (7.5) so the
                // visual icon edge aligns with the header text at xl.
                left: buildContext.theme.spacing.xl - 7.5,
                right: buildContext.theme.spacing.sm,
              ),
              child: Button.icon(
                primaryActivityCommand(activity),
                selected: activity.doNow,
                selectedColor: activityColor,
                forceHover: isHovered,
              ),
            ),
          ],
        );
      },
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasSubPriorityLabel)
            Padding(
              padding: EdgeInsets.only(top: buildContext.theme.spacing.md),
              child: PriorityLabel(
                priority: activity.priority,
                context: context,
                fontSize: buildContext.theme.typography.xs.fontSize,
              ),
            ),
          Padding(
            padding: EdgeInsets.only(
              top: hasSubPriorityLabel ? 2.0 : buildContext.theme.spacing.md,
              bottom: buildContext.theme.spacing.md,
              right: buildContext.theme.spacing.sm,
            ),
            child: Text.rich(
              overflow: TextOverflow.ellipsis,
              style: buildContext.theme.typography.base.copyWith(
                color: buildContext.colour.foreground,
              ),
              TextSpan(
                children: [
                  if (activity.assigneeId != null &&
                      !activity.assigneeId!.isCurrentUser)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: buildContext.theme.spacing.md,
                        ),
                        child: Initials(
                          actorId: activity.assigneeId,
                          size: buildContext.theme.iconSizes.sm,
                          fallback: null,
                        ),
                      ),
                    ),
                  TextSpan(
                    text: activity.displayTitle,
                    style: now
                        ? TextStyle(
                            color: buildContext.colour.colours.fromTheme(
                              activity.priority.displayColor,
                            ),
                          )
                        : selected
                        ? TextStyle(color: buildContext.colour.foreground)
                        : null,
                  ),
                  if (activity.preview != null &&
                      activity.preview!.isNotEmpty &&
                      activity.preview != activity.displayTitle)
                    TextSpan(
                      text: '  ${activity.preview}',
                      style: TextStyle(color: buildContext.colour.muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      trailingBuilder: (isHovered, hasFocus) => Padding(
        padding: EdgeInsets.only(
          top: labelOffset,
          right: (isTouchDevice && reorderableIndex != null)
              ? 0
              : buildContext.theme.spacing.xl,
        ),
        child: ActivityCommands(
          activity: activity,
          tagSuggestions: tagSuggestions,
          showCommands: isHovered || hasFocus,
        ),
      ),
      selected: selected,
      focusNode: focusNode,
      onHover: onHover,
      reorderableIndex: reorderableIndex,
    );
  }

  @override
  Widget build(BuildContext buildContext) {
    final isTouchDevice = !hasPhysicalKeyboard();
    final listTile = _buildListTile(buildContext, isTouchDevice);

    // Desktop: right-click context menu, no drag handle
    if (!isTouchDevice) {
      return ContextMenu(
        items: () => activityCommands(activity)
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

class ActivityCommands extends HookWidget {
  const ActivityCommands({
    required this.activity,
    this.tagSuggestions = const [],
    this.showCommands = false,
    super.key,
  });

  final Activity activity;
  final List<Tag> tagSuggestions;
  final bool showCommands;

  @override
  Widget build(BuildContext context) {
    // Compute activity color for selected buttons
    final activityColor = context.colour.colours.fromTheme(
      activity.priority.displayColor,
    );

    // Get tags that this activity has
    // Exclude Tag.now for doNow activities since it's shown as leading command
    // Exclude Tag.later for doLater activities since it's shown as leading icon
    // Exclude Tag.done for done activities since it's shown as leading icon
    final activityTags = useMemoized(
      () => Tag.getAll(onlyAddable: true)
          .where(
            (tag) =>
                activity.hasTag(tag) &&
                ![Tag.now, Tag.later, Tag.someday, Tag.done].contains(tag),
          )
          .toList(),
      [
        activity.tags,
        activity.doNow,
        activity.doLater,
        activity.doSomeday,
        activity.done,
      ],
    );

    // Create futures to load actor names for tooltips - memoized to avoid recreating on every build
    final tagFutures = useMemoized(
      () => activityTags.map((tag) async {
        final key = ValueKey(Object.hash(activity.id, tag.id));

        // Use FinishActivity when clicking Tag.now on a "doNow" activity
        final command = tag == Tag.now
            ? FinishAction(activity, stateIcon: true)
            : ToggleActivityTag(activity, tag);

        // Get actor names for tooltip
        final actorNames = await activity.getTagActorNames(tag);

        // Wrap command with subtitle showing actor names
        final wrappedCommand = actorNames.isNotEmpty
            ? CommandWrapper(command, subtitle: Value(actorNames))
            : command;

        final count = activity.tags[tag]?.length ?? 0;

        // Use pulsing animation for twist tags
        if (tag == Tag.twist) {
          return CountBadge(
            count: count,
            child: PulsingColorButton(
              wrappedCommand,
              key: key,
              primaryColor: activityColor,
            ),
          );
        }

        return CountBadge(
          count: count,
          child: Button.icon(
            wrappedCommand,
            key: key,
            selected: true,
            selectedColor: activityColor,
          ),
        );
      }).toList(),
      [activity.id, activity.tags],
    );

    // Get commands (only if showCommands is true)
    final activityCommandButtons = showCommands
        ? activityCommands(
            activity,
            skipInfrequent: true,
            skipPrimary: true, // Exclude primary command from trailing
          ).map((cmd) => Button.icon(cmd)).toList()
        : <Widget>[];

    final tagSuggestionButtons = showCommands
        ? topActivityTags(
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
            : activityTags
                  .map((tag) {
                    final key = ValueKey(Object.hash(activity.id, tag.id));
                    final command = tag == Tag.now
                        ? FinishAction(activity, stateIcon: true)
                        : ToggleActivityTag(activity, tag);
                    final count = activity.tags[tag]?.length ?? 0;
                    // Use pulsing animation for twist tags
                    if (tag == Tag.twist) {
                      return CountBadge(
                        count: count,
                        child: PulsingColorButton(
                          command,
                          key: key,
                          primaryColor: activityColor,
                        ),
                      );
                    }
                    return CountBadge(
                      count: count,
                      child: Button.icon(
                        command,
                        key: key,
                        selected: true,
                        selectedColor: activityColor,
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
              ...activityCommandButtons,
              ...tagSuggestionButtons,
            ].take((5 - loadedTagButtons.length).clamp(0, 5)),
            // Always add ShowActivityCommands as the 6th button
            Button.icon(
              CommandWrapper(
                ShowActivityCommands(activity),
                icon: Value(PlotIcon.more),
              ),
            ),
            ...loadedTagButtons.take(5),
          ];
        } else {
          allButtons = loadedTagButtons;
        }

        return Row(mainAxisSize: MainAxisSize.min, children: allButtons);
      },
    );
  }
}
