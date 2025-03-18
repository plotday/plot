import 'package:flutter/material.dart';

import 'package:plot/store/store.dart';
import 'event.dart';

class DateWidget extends StatelessWidget {
  const DateWidget({
    required this.day,
    required this.onSelect,
    this.selected = false,
    this.allDayEvents = const [],
    super.key,
  });

  final ScheduledDay day;
  final bool selected;
  final void Function() onSelect;
  final List<Event> allDayEvents;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(),
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
      ),
    );
  }
}

class PriorityBlockWidget extends StatelessWidget {
  const PriorityBlockWidget({
    required this.priority,
    required this.children,
    super.key,
  });

  final Priority priority;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
        // color: const ThemeColor.defaultColor().getBackground(context),
        child: Column(
      children: children,
    ));
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
    List<Widget> children = [
      DateWidget(
        day: day,
        onSelect: () => {},
        allDayEvents: day.allDayEvents,
      ),
    ];

    List<Event> currentEvents = [];
    Priority? currentPriority;

    void addPriorityBlock() {
      if (currentEvents.isEmpty || currentPriority == null) return;
      children.add(
        PriorityBlockWidget(
          priority: currentPriority,
          children: currentEvents
              .map(
                (e) => EventWidget(
                  event: e,
                  onSelect: () => onSelect(e),
                  selected: e.id == selected?.id ||
                      (selected?.unsaved == true &&
                          selected?.at.start == e.at.start),
                ),
              )
              .toList(),
        ),
      );
    }

    for (final event in day.events) {
      if (currentPriority == event.priority) {
        currentEvents.add(event);
      } else {
        addPriorityBlock();
        currentPriority = event.priority;
        currentEvents = [event];
      }
    }
    addPriorityBlock();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
