import 'package:flutter/material.dart';
import 'package:plot/util/time.dart';

import 'scheduled_event.dart';
import 'scheduled_event_widget.dart';

class DayWidget extends StatelessWidget {
  const DayWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(day.day.friendly),
      ...day.events.map((event) => ScheduledEventWidget(event: event)),
    ]);
  }
}
