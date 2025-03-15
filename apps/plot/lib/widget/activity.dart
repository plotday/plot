import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/util/theme_color.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    required this.onChange,
    this.onTap,
    this.selected = false,
    super.key,
  });

  final Activity activity;
  final VoidCallback? onTap;
  final void Function(Activity) onChange;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: selected,
      leading: switch (activity) {
        _ when activity.pinned => IconButton(
            onPressed: () {
              onChange(activity.copyWith(pinned: false));
              Posthog().capture(
                eventName: 'Activity Un-pinned',
              );
            },
            icon: PlotIcon.pinned,
          ),
        _ when activity.doNow => IconButton(
            onPressed: () {
              onChange(activity.copyWith(doneAt: Value(DateTime.now())));
              Posthog().capture(
                eventName: 'Activity Started',
              );
            },
            icon: PlotIcon.todo,
          ),
        _ when activity.done => IconButton(
            onPressed: () {
              onChange(activity.copyWith(doAt: Value(DateTime.now())));
              Posthog().capture(
                eventName: 'Activity Completed',
              );
            },
            icon: PlotIcon.done,
          ),
        _ when activity.scheduled => IconButton(
            onPressed: () {
              Posthog().capture(
                eventName: 'Activity Scheduled',
              );
            },
            icon: PlotIcon.scheduled,
          ),
        _ => null,
      },
      leadingSize: const Size(18, 18),
      title: Text(activity.body),
    );
  }
}
