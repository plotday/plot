import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'package:plot/widget/day.dart';
import 'package:plot/util/time.dart';

class ScheduleWidget extends StatelessWidget {
  const ScheduleWidget({this.scrollController, super.key});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, scheduleState) => BidirectionalList(
        count: scheduleState.schedule.length,
        offset:
            scheduleState.anchor.difference(scheduleState.range.start).inDays,
        scrollController: scrollController,
        fetcher: (move, count) async {
          final start = scheduleState.range.start.addDays(move);
          final end = start.addDays(count);
          await context.read<ScheduleBloc>().watch(DateRangeCustom(start, end));
        },
        builder: (context, index) {
          final day =
              scheduleState.schedule[scheduleState.range.start.addDays(index)];
          if (day == null) return null;
          return Column(children: [
            DayWidget(
              day: day,
            ),
            const SizedBox(
              height: 8,
            ),
          ]);
        },
      ),
    );
  }
}
