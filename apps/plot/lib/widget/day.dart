import 'package:flutter/material.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';
import 'event.dart';
import 'squiggle.dart';

class DateWidget extends StatelessWidget {
  const DateWidget({
    required this.day,
    required this.onSelect,
    this.selected = false,
    this.firstEvent,
    this.allDayEvents = const [],
    super.key,
  });

  final ScheduledDay day;
  final bool selected;
  final void Function() onSelect;
  final Event? firstEvent;
  final List<Event> allDayEvents;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(),
      child: Container(
        color: selected
            ? const ThemeColor.defaultColor().getBackground(context)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 72,
                alignment: Alignment.topRight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(day.date.format(format: 'E')),
                    const SizedBox(width: 4),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: const ThemeColor.defaultColor()
                                .getForeground(context),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          day.date.toDateTime().format('d'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Squiggle()),
              // Expanded(
              //   child: Row(
              //     children: [
              //       Text(
              //         day.date.year == DateTime.now().year
              //             ? day.date.toDateTime().format('MMMM')
              //             : day.date.toDateTime().format('MMMM yyyy'),
              //         style: Theme.of(context).textTheme.titleSmall?.copyWith(
              //               color: Colors.grey,
              //             ),
              //         textAlign: TextAlign.end,
              //       ),
              //     ],
              //   ),
              // ),
            ],
          ),
        ),
      ),
    );
  }
}

class DayWidget extends StatelessWidget {
  const DayWidget({
    required this.day,
    required this.onSelect,
    this.selected,
    super.key,
  });

  final ScheduledDay day;
  final Event? selected;
  final void Function(Event) onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DateWidget(
          day: day,
          onSelect: () => onSelect(Event(
            at: day.date.toDateTimeRange(),
          )),
          selected: selected?.isBlank == true &&
              selected!.start.toDate() == day.date &&
              selected!.start <= day.events.first.start,
          firstEvent: day.events.firstOrNull,
          allDayEvents: day.allDayEvents,
        ),
        ...day.events
            .where((e) => !e.isBlank || !e.at.start.toTimeOfDay().isMidnight)
            .map(
              (event) => EventWidget(
                event: event,
                onSelect: () => onSelect(event),
                selected: event.id == selected?.id ||
                    (selected?.isBlank == true &&
                        event.isBlank &&
                        selected?.at.start == event.at.start),
              ),
            ),
      ],
    );
  }
}
