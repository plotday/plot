import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:plot/now/pomodoro_widget.dart';

import '../util/api.dart' as api;
import '../util/time.dart';

import 'scheduled_event.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  Future<void> _rsvp(EventResponse response) async {
    await api.put(
      "/event/${event.id}/rsvp",
      body: {
        'response': response.name,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 85,
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: event.at.isNow()
              ? const PomodoroWidget()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: <TextSpan>[
                          TextSpan(
                            text: event.at.start.clockString,
                            style: const TextStyle(fontWeight: FontWeight.bold),
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
                    Text.rich(
                      TextSpan(
                        children: <TextSpan>[
                          if (event.at.duration.hasHours)
                            TextSpan(
                              text: event.at.duration.hoursString,
                            ),
                          if (event.at.duration.hasHours)
                            const TextSpan(
                              text: 'H',
                              style: TextStyle(fontSize: 10),
                            ),
                          const TextSpan(text: ' '),
                          if (event.at.duration.hasMinutes)
                            TextSpan(
                              text: event.at.duration.minutesString,
                            ),
                          if (event.at.duration.hasMinutes)
                            const TextSpan(
                              text: 'M',
                              style: TextStyle(fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: Text(event.name),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _rsvp(EventResponse.declined);
          },
        )
      ],
    );
  }
}
