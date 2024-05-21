import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/model/schedule.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'package:plot/widget/day.dart';
import 'package:plot/util/time.dart';

class ScheduleWidget extends StatelessWidget {
  ScheduleWidget({super.key}) : anchor = Date.today();

  final Date anchor;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, scheduleState) => BidirectionalList(
        onFetch: (index, reverse) async {
          final start = anchor.addDays(index);
          final end = await ScheduledDay.fetch(start,
              direction:
                  reverse ? TimeDirection.descending : TimeDirection.ascending);
          return index +
              (reverse ? -1 : 1) * end.difference(start).inDays.abs();
        },
        itemBuilder: (context, index) => Column(children: [
          DayWidget(
            day: ScheduledDay.get(anchor.addDays(index)),
          ),
          const SizedBox(
            height: 8,
          ),
        ]),
      ),
    );
  }
}
