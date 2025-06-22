import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ActivityList extends StatelessWidget {
  const ActivityList({
    super.key,
    required this.activities,
    required this.priority,
  });

  final List<Activity> activities;
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return const SizedBox();
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(width: 1.0, color: context.colour.border),
        ),
      ),
      child: Column(
        children: [
          ReorderableListView<Activity>(
            list: activities,
            itemBuilder: (buildContext, activity) =>
                ActivityWidget(activity: activity, context: null),
            shrinkWrap: true,
            onReorder: (int oldIndex, int newIndex) async {
              var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
              var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

              final currentActivity = activities[oldIndex];
              Activity? previous;
              if (previousIndex >= 0) {
                previous = activities[previousIndex];
              }
              Activity? next;
              if (nextIndex < activities.length) {
                next = activities[nextIndex];
              }
              currentActivity
                  .copyWith(
                    order: Order.between(
                      previous?.order,
                      previous?.doAt == null || next?.doAt == previous?.doAt
                          ? next?.order
                          : null,
                    ),
                    doAt: currentActivity.doNow
                        ? Value(
                            previous?.doAt ?? next?.doAt ?? currentActivity.doAt,
                          )
                        : const Value.absent(),
                  )
                  .save();
            },
          ),
        ],
      ),
    );
  }
}