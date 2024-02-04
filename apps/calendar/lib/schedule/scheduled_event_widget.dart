import 'package:flutter/material.dart';
import 'package:plot/now/pomodoro_widget.dart';

import '../util/time.dart';
import '../util/duration_widget.dart';

import 'scheduled_event.dart';
import 'scheduled_event_menu.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 80,
          padding: const EdgeInsets.only(left: 8, right: 8),
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
        ScheduledEventMenu(event: event),
      ],
    );
  }
}
