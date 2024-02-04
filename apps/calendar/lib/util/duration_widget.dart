import 'package:flutter/material.dart';

import '../util/time.dart';

class DurationWidget extends StatelessWidget {
  const DurationWidget({required this.duration, super.key});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
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
