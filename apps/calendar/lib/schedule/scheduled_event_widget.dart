import 'package:flutter/material.dart';
import 'package:plot/now/pomodoro_widget.dart';

import '../util/api.dart' as api;
import '../util/time.dart';
import '../util/duration_widget.dart';

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
                        style: const TextStyle(height: 0.8),
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
                    const SizedBox(height: 4),
                    DurationWidget(
                      duration: event.at.duration,
                    )
                  ],
                ),
        ),
        Expanded(
          child: Text(event.name,
              style: const TextStyle(fontWeight: FontWeight.w500, height: 0.8)),
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
