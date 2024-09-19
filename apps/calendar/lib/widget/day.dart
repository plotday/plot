import 'package:flutter/material.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/time.dart';
import 'event.dart';

class DateWidget extends StatelessWidget {
  const DateWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 72,
            alignment: Alignment.topRight,
            child: Stack(
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
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Text(
                  day.date.year == DateTime.now().year
                      ? day.date.toDateTime().format('MMMM')
                      : day.date.toDateTime().format('MMMM yyyy'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.grey,
                      ),
                  textAlign: TextAlign.end,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DayWidget extends StatelessWidget {
  const DayWidget({required this.day, super.key});

  final ScheduledDay day;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DateWidget(day: day),
        ...day.events.map((event) => EventWidget(event: event)),
      ],
    );
  }
}
