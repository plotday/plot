import 'package:flutter/material.dart';

import '../util/time.dart';
import '../util/duration_widget.dart';
import '../util/api.dart' as api;

import 'scheduled_event.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 70,
            padding: const EdgeInsets.only(right: 8),
            alignment: Alignment.centerRight,
            child: Text.rich(
              TextSpan(
                children: <TextSpan>[
                  TextSpan(
                    text: event.at.start.clockString,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const TextSpan(text: ' '),
                  TextSpan(
                    text: event.at.start.meridiem,
                    style: const TextStyle(
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                      Widget? child) =>
                  InkWell(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.activity?.name ?? 'Open',
                    ),
                    if (event.name != null)
                      Text(
                        event.name!,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                  ],
                ),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              ),
              menuChildren: [
                if (event.id != null && event.at.end.isAfter(DateTime.now()))
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.event_busy),
                    onPressed: () => {_rsvp(EventResponse.declined)},
                    child: const Text('Release time'),
                  ),
              ],
            ),
          ),
          Container(
              width: 70,
              padding: const EdgeInsets.only(left: 8, right: 4),
              alignment: Alignment.centerRight,
              child: DurationWidget(
                duration: event.at.duration,
              )),
        ],
      ),
    );
  }

  Future<void> _rsvp(EventResponse response) async {
    await api.put(
      "/event/${event.id}/rsvp",
      body: {
        'response': response.name,
      },
    );
  }
}
