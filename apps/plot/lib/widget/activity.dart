import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_link.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';

class ActivityWidget extends StatefulWidget {
  const ActivityWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    super.key,
  });

  final Activity activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  @override
  State<ActivityWidget> createState() => _ActivityWidgetState();
}

class _ActivityWidgetState extends State<ActivityWidget> {
  Command? _getSwipeRightCommand() {
    if (widget.activity.type == ActivityType.event) return null;
    return widget.activity.doNow
        ? FinishActivity(widget.activity)
        : StartActivity(widget.activity);
  }

  Command? _getSwipeLeftCommand() {
    if (widget.activity.type == ActivityType.event) return null;
    return PickScheduleActivity(widget.activity);
  }

  Widget _buildListTile(BuildContext buildContext, bool isTouchDevice) {
    final hasVisibleLinks = widget.activity.links.isNotEmpty;

    return ListTile(
      command: CommandWrapper(
        ChangeCurrentActivity(widget.activity),
        icon: Value(null),
      ),
      longPressCommand: isTouchDevice
          ? ShowActivityCommands(widget.activity)
          : null,
      title: widget.activity.displayTitle,
      subtitle: widget.activity.note != null && widget.activity.note!.isNotEmpty
          ? widget.activity.noteText
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: widget.activity.displayTitle,
                    style: widget.selected
                        ? TextStyle(color: buildContext.colour.accent)
                        : null,
                  ),
                  if (widget.activity.note != null &&
                      widget.activity.note!.isNotEmpty &&
                      widget.activity.noteText != widget.activity.displayTitle)
                    TextSpan(
                      text: ' ${widget.activity.noteText}',
                      style: TextStyle(color: buildContext.colour.muted),
                    ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
              style: buildContext.theme.typography.base.copyWith(
                color: buildContext.colour.foreground,
              ),
            ),
          ),
          if (hasVisibleLinks) ...[
            const SizedBox(height: 8),
            ActivityLinksList(activity: widget.activity),
          ],
        ],
      ),
      trailing: ActivityTags(activity: widget.activity, reverse: true),
      trailingCommands: [
        ShowActivityCommands(widget.activity),
        ...activitySecondaryCommands(widget.activity).toList().reversed,
      ],
      revealTrailingCommands: true,
      selected: widget.selected,
      focusNode: widget.focusNode,
      onHover: widget.onHover,
      reorderableIndex: widget.reorderableIndex,
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
      key: ValueKey(widget.activity.id),
      startCommand: swipeRightCommand,
      endCommand: swipeLeftCommand,
      child: listTile,
    );
  }
}

class ActivityTags extends StatelessWidget {
  const ActivityTags({required this.activity, this.reverse = false, super.key});

  final Activity activity;
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    var relevantTags = Tag.getAll().where((tag) => activity.hasTag(tag));
    if (reverse) {
      relevantTags = relevantTags.toList().reversed;
    }

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: relevantTags.map((tag) {
        final hasTag = activity.hasTag(tag);
        final key = ValueKey(Object.hash(activity.id, tag.id));

        // Use FinishActivity when clicking Tag.now on a "doNow" activity
        final command = tag == Tag.now && hasTag
            ? FinishActivity(activity)
            : ToggleActivityTag(activity, tag);

        return Button.icon(command, key: key, selected: hasTag);
      }).toList(),
    );
  }
}

class ActivityDetailWidget extends StatefulWidget {
  const ActivityDetailWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    super.key,
  });

  final Activity activity;
  final Activity? context;
  final bool selected;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;

  @override
  State<ActivityDetailWidget> createState() => _ActivityDetailWidgetState();
}

class _ActivityDetailWidgetState extends State<ActivityDetailWidget> {
  bool _isHovered = false;

  bool get _showCommands => _isHovered || (widget.focusNode?.hasFocus ?? false);

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(ActivityDetailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChange);
      widget.focusNode?.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {});
  }

  void _setHovered(bool hovered) {
    if (_isHovered != hovered) {
      setState(() {
        _isHovered = hovered;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVisibleLinks = widget.activity.links.isNotEmpty;
    final activityTime = widget.activity.doneAt ?? widget.activity.createdAt;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: ListTile(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Viewer(
              markdown: widget.activity.note ?? widget.activity.displayTitle,
            ),
            if (hasVisibleLinks) ...[
              const SizedBox(height: 8),
              ActivityLinksList(activity: widget.activity),
            ],
            Stack(
              children: [
                // Base layer - tags and timestamp
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ActivityTags(activity: widget.activity),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        activityTime.toTimeAgo(),
                        style: context.theme.typography.xs.copyWith(
                          color: context.colour.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                // Overlay layer - commands that cover timestamp
                Row(
                  children: [
                    // Invisible spacer same width as tags
                    Opacity(
                      opacity: 0,
                      child: ActivityTags(activity: widget.activity),
                    ),
                    if (_showCommands)
                      ...[
                        ...activitySecondaryCommands(widget.activity),
                        ShowActivityCommands(widget.activity, open: false),
                      ].asMap().entries.map(
                        (entry) => Button.icon(entry.value),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
        selected: widget.selected,
        focusNode: widget.focusNode,
        onHover: widget.onHover,
        reorderableIndex: widget.reorderableIndex,
      ),
    );
  }
}
