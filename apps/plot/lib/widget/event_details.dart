import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class EventDetails extends StatelessWidget {
  const EventDetails({super.key, required this.event, required this.onChanged});

  final Event event;
  final void Function(Event) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (event.priority?.title != null) Text(event.priority!.title),
          Row(
            children: [
              Text(event.at.start.toDate().format()),
              const SizedBox(width: 8),
              TimeRangePicker(
                onChanged: (at) {
                  onChanged(event.copyWith(at: at));
                },
                value: event.at,
              ),
            ],
          ),
          TextField(
            label: "Title",
            value: event.name,
            onChanged: (name) {
              onChanged(event.copyWith(name: Value(name)));
            },
          ),
          PrioritySelector(
            selected: event.priority,
            onSelect: (priority) {
              onChanged(event.copyWith(priorityId: Value(priority.id)));
            },
          ),
          Switch(
            label: const Text("Bookable"),
            value: event.availability == EventAvailability.free,
            onChanged: (free) {
              onChanged(
                event.copyWith(
                  availability: free
                      ? EventAvailability.free
                      : EventAvailability.busy,
                ),
              );
            },
          ),
          Button(ArchiveEventCommand(event)),
        ],
      ),
    );
  }
}
