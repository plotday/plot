import 'package:flutter/material.dart';

import './time.dart';

class TimeWidget extends StatelessWidget {
  const TimeWidget({required this.time, super.key});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          TextSpan(
            text: time.clockString,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: time.meridiem,
            style: const TextStyle(
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class DurationWidget extends StatelessWidget {
  const DurationWidget({required this.duration, super.key});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          if (!duration.hasHours && !duration.hasMinutes)
            const TextSpan(text: '—'),
          if (duration.hasHours)
            TextSpan(
              text: duration.hoursString,
            ),
          if (duration.hasHours)
            const TextSpan(
              text: 'H',
              style: TextStyle(fontSize: 10),
            ),
          if (duration.hasHours && duration.hasMinutes)
            const TextSpan(text: ' '),
          if (duration.hasMinutes)
            TextSpan(
              text: duration.minutesString,
            ),
          if (duration.hasMinutes)
            const TextSpan(
              text: 'M',
              style: TextStyle(fontSize: 10),
            ),
        ],
      ),
    );
  }
}
