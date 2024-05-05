import 'package:flutter/material.dart';

import 'package:plot/model/schedule.dart';
import 'event.dart';

class DayWidget extends StatelessWidget {
  const DayWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(day.date.format(), style: Theme.of(context).textTheme.titleMedium),
      ...day.events.map((event) => EventWidget(event: event)),
    ]);
  }
}
