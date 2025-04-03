import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    super.key,
  });

  final Activity activity;

  @override
  Widget build(BuildContext context) {
    return ListTile.command(
      ChangeCurrentActivity(activity),
      commands: activityCommands(activity).commands,
    );
  }
}
