import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ThreadList extends StatelessWidget {
  const ThreadList({
    super.key,
    required this.activities,
    required this.priority,
  });

  final List<Thread> activities;
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return const SizedBox();
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(width: 1.0, color: context.theme.colors.border),
        ),
      ),
      child: Column(
        children: [
          ReorderableListView<Thread>(
            list: activities,
            itemBuilder: (buildContext, activity, reorderableIndex) =>
                ThreadWidget(
                  activity: activity,
                  reorderableIndex: reorderableIndex,
                ),
            shrinkWrap: true,
            onReorder: (int oldIndex, int newIndex) async {
              var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
              var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);

              final currentActivity = activities[oldIndex];
              Thread? previous;
              if (previousIndex >= 0) {
                previous = activities[previousIndex];
              }
              Thread? next;
              if (nextIndex < activities.length) {
                next = activities[nextIndex];
              }
              // For todo tasks, try to inherit scheduling from neighboring tasks
              if (currentActivity.todo) {
                DateRange? inheritedOn;
                DateTimeRange? inheritedAt;

                // Check previous task for scheduling to inherit
                if (previous?.on != null) {
                  inheritedOn = previous?.on;
                } else if (previous?.at != null) {
                  inheritedAt = previous?.at;
                }

                // If previous didn't have scheduling, check next task
                if (inheritedOn == null && inheritedAt == null) {
                  if (next?.on != null) {
                    inheritedOn = next?.on;
                  } else if (next?.at != null) {
                    inheritedAt = next?.at;
                  }
                }

                // Use current activity's scheduling as fallback, or default to date-based
                if (inheritedOn == null && inheritedAt == null) {
                  if (currentActivity.on != null) {
                    inheritedOn = currentActivity.on;
                  } else if (currentActivity.at != null) {
                    inheritedAt = currentActivity.at;
                  } else {
                    inheritedOn = CustomDateRange(Date.today(), null);
                  }
                }

                return currentActivity
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                      on: inheritedAt == null
                          ? Value(inheritedOn)
                          : const Value(null),
                      at: inheritedOn == null
                          ? Value(inheritedAt)
                          : const Value(null),
                    )
                    .save();
              } else {
                // For non-doNow tasks, just update order
                return currentActivity
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                    )
                    .save();
              }
            },
          ),
        ],
      ),
    );
  }
}
