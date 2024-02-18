import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'scheduled_event.dart';
import 'day_widget.dart';
import 'bloc.dart';
import '../util/infinite_time_widget.dart';
import '../util/time.dart';

class ScheduleWidget extends StatelessWidget {
  const ScheduleWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return InfiniteTimeWidget<ScheduledDay>(
      stream: context.read<ScheduleBloc>().stream.map((state) =>
          PagedItemsState<ScheduledDay>(
              Map.fromEntries(TimeDirection.values.map((direction) => MapEntry(
                  direction,
                  DualList<DateTime, ScheduledDay>(
                    state.lists[direction]!.events.entries
                        .map<ScheduledDay>((entry) =>
                            ScheduledDay(Time.day(entry.key), entry.value))
                        .toList(),
                    state.lists[direction]!.nextAnchor,
                  )))))),
      onFetch: (pageKey, direction) async {
        context.read<ScheduleBloc>().add(ScheduleFetch(pageKey, direction));
      },
      builderDelegate: PagedChildBuilderDelegate<ScheduledDay>(
          itemBuilder: (context, item, index) => Column(children: [
                DayWidget(
                  day: item,
                ),
                const SizedBox(
                  height: 8,
                ),
              ])),
      anchor: Time.today().start,
    );
  }
}
