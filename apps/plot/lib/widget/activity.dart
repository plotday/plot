import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
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
  Widget build(BuildContext _) {
    return ListTile(
      command: ChangeCurrentActivity(activity),
      title: activity.displayTitle,
      leadingCommand: activityPrimaryCommand(activity),
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
    return ListTile(
      command: !isContext ? ChangeCurrentActivity(activity) : null,
      trailingCommands: [ShowActivityCommands(activity)],
      body: Column(
        children: [
          Viewer(
            markdown: activity.note ?? activity.displayTitle,
            onTap: () {
              context.run(ChangeCurrentActivity(activity));
            },
          ),
        ],
      ),
      selected: selected,
      onHover: onHover,
    );
  }
}
