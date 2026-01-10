import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
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
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  Command? _getSwipeRightCommand() {
    if (activity.type == ActivityType.event) return null;
    return activity.doNow
        ? FinishAction(activity, stateIcon: true)
        : ToggleAction(activity);
  }

  Command? _getSwipeLeftCommand() {
    if (activity.type == ActivityType.event) return null;
    return PickScheduleActivity(activity);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    // Get tag suggestions from PriorityBloc if available
    final tagSuggestions =
        buildContext.watch<PriorityBloc?>()?.state.tagSuggestions ?? [];

    return ListTile(
      command: CommandWrapper(
        ChangeCurrentActivity(activity),
        icon: Value(null),
      ),
      longPressCommand: isTouchDevice ? ShowActivityCommands(activity) : null,
      title: activity.displayTitle,
      subtitle: activity.preview,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      leadingBuilder: (isHovered, hasFocus) {
        final activityColor = buildContext.colour.colours.fromTheme(
          activity.priority.displayColor,
        );
        return Stack(
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: 6,
              width: 6,
              child: UnreadIndicator(
                color: activity.priority.displayColor,
                unread: activity.unread,
              ),
            ),
            Padding(
              padding: const .only(left: 8.5),
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
          Padding(
            padding: const .only(top: 8, bottom: 8, right: 4),
            child: Text.rich(
              overflow: TextOverflow.ellipsis,
              style: buildContext.theme.typography.base.copyWith(
                color: buildContext.colour.foreground,
              ),
              TextSpan(
                children: [
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
                      text: ' ${activity.preview}',
                      style: TextStyle(color: buildContext.colour.muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      trailingBuilder: (isHovered, hasFocus) => Padding(
        padding: const .only(right: 8.5),
        child: ActivityCommands(
          activity: activity,
          tagSuggestions: tagSuggestions,
          showCommands: isHovered || hasFocus,
          reverse: true,
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

    // Only wrap in Swipeable on touch devices
    if (!isTouchDevice) {
      return listTile;
    }

    final swipeRightCommand = _getSwipeRightCommand();
    final swipeLeftCommand = _getSwipeLeftCommand();

    // If no swipe actions available, just return the list tile
    if (swipeRightCommand == null && swipeLeftCommand == null) {
      return listTile;
    }

    return Swipeable(
      key: ValueKey(activity.id),
      startCommand: swipeRightCommand,
      endCommand: swipeLeftCommand,
      child: listTile,
    );
  }
}

class ActivityCommands extends HookWidget {
  const ActivityCommands({
    required this.activity,
    this.tagSuggestions = const [],
    this.showCommands = false,
    this.reverse = false,
    super.key,
  });

  final Activity activity;
  final List<Tag> tagSuggestions;
  final bool showCommands;
  final bool reverse;

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

        return Button.icon(
          wrappedCommand,
          key: key,
          selected: true,
          selectedColor: activityColor,
        );
      }).toList(),
      [activity.id, activity.tags],
    );

    // Get commands (only if showCommands is true)
    final commandButtons = showCommands
        ? [
            ...activityCommands(
              activity,
              skipInfrequent: true,
              skipPrimary: true, // Exclude primary command from trailing
            ).map((cmd) => Button.icon(cmd)),
            // Add top tag buttons
            ...topActivityTags(
              activity,
              tagSuggestions,
            ).map((cmd) => Button.icon(cmd)),
            Button.icon(
              CommandWrapper(
                ShowActivityCommands(activity),
                icon: Value(PlotIcon.more),
              ),
            ),
          ]
        : <Widget>[];

    // Build the final row with tags and commands
    return FutureBuilder<List<Widget>>(
      future: Future.wait(tagFutures),
      builder: (context, snapshot) {
        // While loading or on error, show buttons without subtitles
        final loadedTagButtons =
            snapshot.hasData && snapshot.connectionState == ConnectionState.done
            ? snapshot.data!
            : activityTags.map((tag) {
                final key = ValueKey(Object.hash(activity.id, tag.id));
                final command = tag == Tag.now
                    ? FinishAction(activity, stateIcon: true)
                    : ToggleActivityTag(activity, tag);
                return Button.icon(
                  command,
                  key: key,
                  selected: true,
                  selectedColor: activityColor,
                );
              }).toList();

        // Combine tags and commands
        final allButtons = reverse
            ? [...commandButtons, ...loadedTagButtons]
            : [...loadedTagButtons, ...commandButtons];
        return Row(mainAxisSize: MainAxisSize.min, children: allButtons);
      },
    );
  }
}
