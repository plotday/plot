import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_link.dart';
import 'package:plot/command/command.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Activity activity;
  final Priority? context;
  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext buildContext) {
    final hasVisibleLinks = activity.links.any((link) => 
      link.type != LinkType.hidden
    );

    return ListTile(
      command: ChangeCurrentActivity(activity),
      title: activity.displayTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  activity.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  style: buildContext.theme.typography.xs.copyWith(
                    color: buildContext.colour.foreground,
                  ),
                ),
              ),
              ActivityTags(activity: activity),
              Button.icon(ShowActivityCommands(activity)),
            ],
          ),
          if (hasVisibleLinks) ...[
            const SizedBox(height: 8),
            ActivityLinksList(activity: activity),
          ],
        ],
      ),
      selected: selected,
      onHover: onHover,
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
        return Button.icon(ToggleActivityTag(activity, tag), selected: hasTag);
      }).toList(),
    );
  }
}

class ActivityDetailWidget extends StatelessWidget {
  const ActivityDetailWidget({
    required this.activity,
    this.context,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Activity activity;
  final Activity? context;
  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    bool isContext = activity == this.context;
    final hasVisibleLinks = activity.links.any((link) => 
      link.type != LinkType.hidden
    );
    
    return ListTile(
      command: !isContext ? ChangeCurrentActivity(activity) : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Viewer(
            markdown: activity.note ?? activity.displayTitle,
            onTap: () {
              context.run(ChangeCurrentActivity(activity));
            },
          ),
          if (hasVisibleLinks) ...[
            const SizedBox(height: 8),
            ActivityLinksList(activity: activity),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ActivityTags(activity: activity),
              Button.icon(ShowActivityCommands(activity)),
            ],
          ),
        ],
      ),
      selected: selected,
      onHover: onHover,
    );
  }
}
