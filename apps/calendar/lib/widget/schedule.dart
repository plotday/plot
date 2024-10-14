import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'package:plot/widget/day.dart';
import 'package:plot/util/time.dart';

class ScheduleWidget extends StatelessWidget {
  ScheduleWidget({this.scrollController, super.key}) : anchor = Date.today();

  final Date anchor;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, scheduleState) => BidirectionalList(
        scrollController: scrollController,
        fetcher: (move, count) async {
          final start = scheduleState.range.start.addDays(move);
          final end = start.addDays(count);
          final schedule = await context
              .read<ScheduleBloc>()
              .watch(DateRangeCustom(start, end));
          return ItemFetchResult(
            count: schedule.length,
            doneStart: false,
            doneEnd: false,
          );
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
