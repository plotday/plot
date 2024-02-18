import 'package:flutter/material.dart';

import '../util/time.dart';
import '../util/duration_widget.dart';

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
                // style: const TextStyle(height: 0.8),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.activity?.name ?? 'Open',
                  // style: const TextStyle(height: 0.8),
                ),
                if (event.name != null)
                  Text(
                    event.name!,
                    style: const TextStyle(fontWeight: FontWeight.w500),
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
          // ScheduledEventMenu(event: event),
        ],
      ),
    );
  }
}
