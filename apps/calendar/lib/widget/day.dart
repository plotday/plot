import 'package:flutter/material.dart';

import 'package:plot/model/schedule.dart';
import 'package:plot/util/time.dart';
import 'event.dart';

class DateWidget extends StatelessWidget {
  const DateWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            day.date.toDateTime().format('EEEE'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.grey,
                ),
            textAlign: TextAlign.end,
          ),
        ),
        const SizedBox(width: 8),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.primaries.first,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              day.date.toDateTime().format('d'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            day.date.toDateTime().format('MMMM'),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.grey,
                ),
            textAlign: TextAlign.start,
          ),
        ),
      ],
    );
  }
}

class DayWidget extends StatelessWidget {
  const DayWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
          child: DateWidget(day: day),
        ),
        ...day.events.map((event) => EventWidget(event: event)),
      ],
    );
  }
}
