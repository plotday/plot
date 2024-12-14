import 'package:flutter/widgets.dart';

import 'package:plot/widget/bidirectional_list.dart';
import 'package:plot/widget/day.dart';
import 'package:plot/store/store.dart';

class ScheduleWidget extends StatelessWidget {
  const ScheduleWidget({
    required this.schedule,
    required this.range,
    required this.anchor,
    required this.fetcher,
    required this.onSelect,
    this.selected,
    this.scrollController,
    super.key,
  });

  final ScrollController? scrollController;
  final Map<Date, ScheduledDay> schedule;
  final DateRange range;
  final Date anchor;
  final Future<void> Function(DateRange range) fetcher;
  final void Function(Event) onSelect;
  final Event? selected;

  @override
  Widget build(BuildContext context) {
    return BidirectionalList(
      count: schedule.length,
      offset: anchor.difference(range.start).inDays,
      scrollController: scrollController,
      fetcher: (move, count) async {
        final start = range.start.addDays(move);
        final end = start.addDays(count);
        await fetcher(DateRangeCustom(start, end));
      },
      builder: (context, index) {
        final day = schedule[range.start.addDays(index)];
        if (day == null) return null;
        return Column(children: [
          DayWidget(
            day: day,
            onSelect: onSelect,
            selected: selected,
          ),
        ]);
      },
    );
  }
}
