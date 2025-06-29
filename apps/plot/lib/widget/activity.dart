import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Activity activity;
  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      command: ChangeCurrentActivity(activity),
      title: activity.title,
      leadingCommand: activityPrimaryCommand(activity),
      leadingWidth: 60,
      trailingCommands: [ShowActivityCommands(activity)],
      selected: selected,
      onHover: onHover,
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
    bool expanded =
        isContext || (!activity.doNow && !activity.done && !activity.pinned);
    return ListTile(
      command: !isContext ? ChangeCurrentActivity(activity) : null,
      leadingCommand: activityPrimaryCommand(activity),
      leadingWidth: 60,
      trailingCommands: [ShowActivityCommands(activity)],
      body: Viewer(
        markdown: (expanded ? activity.note : null) ?? activity.title,
        onTap: () {
          context.run<void>(ChangeCurrentActivity(activity));
        },
      ),
      selected: selected,
      onHover: onHover,
    );
  }
}
