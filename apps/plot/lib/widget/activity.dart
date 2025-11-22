import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_link.dart';
import 'package:plot/command/command.dart';

class ActivityWidget extends StatefulWidget {
  const ActivityWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.highlighted = false,
    this.focusNode,
    this.onHover,
    super.key,
  });

  final Activity activity;
  final Priority? context;
  final bool highlighted;
  final bool selected;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;

  @override
  State<ActivityWidget> createState() => _ActivityWidgetState();
}

class _ActivityWidgetState extends State<ActivityWidget> {
  bool _isHovered = false;
  double _dragOffset = 0;

  bool get _showCommands => _isHovered || (widget.focusNode?.hasFocus ?? false);

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(ActivityWidget oldWidget) {
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
  Widget build(BuildContext buildContext) {
    final hasVisibleLinks = widget.activity.links.isNotEmpty;

    return ListTile(
      command: CommandWrapper(
        ChangeCurrentActivity(widget.activity),
        icon: Value(null),
      ),
      title: widget.activity.displayTitle,
      subtitle: widget.activity.note != null && widget.activity.note!.isNotEmpty
          ? widget.activity.noteText
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              setState(() {
                _dragOffset += details.delta.dx;
              });
            },
            onHorizontalDragEnd: (details) {
              if (_dragOffset < -50) {
                // Swiped left - show commands
                _setHovered(true);
              } else if (_dragOffset > 50) {
                // Swiped right - hide commands
                _setHovered(false);
              }
              setState(() {
                _dragOffset = 0;
              });
            },
            child: MouseRegion(
              onEnter: (_) => _setHovered(true),
              onExit: (_) => _setHovered(false),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
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
                                widget.activity.noteText !=
                                    widget.activity.displayTitle)
                              TextSpan(
                                text: ' ${widget.activity.noteText}',
                                style: TextStyle(
                                  color: buildContext.colour.muted,
                                ),
                              ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: buildContext.theme.typography.base.copyWith(
                          color: buildContext.colour.foreground,
                        ),
                      ),
                    ),
                  ),
                  ActivityTags(activity: widget.activity),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    child: _showCommands
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ...activitySecondaryCommands(
                                widget.activity,
                              ).take(3).map((cmd) => Button.icon(cmd)),
                              Button.icon(
                                ShowActivityCommands(widget.activity),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          if (hasVisibleLinks) ...[
            const SizedBox(height: 8),
            ActivityLinksList(activity: widget.activity),
          ],
        ],
      ),
      selected: widget.selected,
      focusNode: widget.focusNode,
      onHover: widget.onHover,
    );
  }
}

class ActivityTags extends StatelessWidget {
  const ActivityTags({required this.activity, super.key});

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final relevantTags = Tag.getAll().where((tag) => activity.hasTag(tag));

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: relevantTags.map((tag) {
        final hasTag = activity.hasTag(tag);
        final key = ValueKey(Object.hash(activity.id, tag.id));
        return Button.icon(
          ToggleActivityTag(activity, tag),
          key: key,
          selected: hasTag,
        );
      }).toList(),
    );
  }
}

class ActivityDetailWidget extends StatelessWidget {
  const ActivityDetailWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.focusNode,
    this.onHover,
    super.key,
  });

  final Activity activity;
  final Activity? context;
  final bool selected;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    final hasVisibleLinks = activity.links.isNotEmpty;

    return ListTile(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Viewer(markdown: activity.note ?? activity.displayTitle),
          if (hasVisibleLinks) ...[
            const SizedBox(height: 8),
            ActivityLinksList(activity: activity),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ActivityTags(activity: activity),
              Button.icon(ShowActivityCommands(activity, open: false)),
            ],
          ),
        ],
      ),
      selected: selected,
      focusNode: focusNode,
      onHover: onHover,
    );
  }
}
