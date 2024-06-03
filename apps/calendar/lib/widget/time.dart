import 'package:flutter/material.dart';

import 'package:plot/util/time.dart';

class TimeWidget extends StatelessWidget {
  const TimeWidget({required this.time, super.key});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final parts = time.toTimeOfDay().format(context).split(' ');
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          TextSpan(
            text: parts[0],
            style: const TextStyle(
              fontWeight: FontWeight.w500,
            ),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: parts[1],
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
    double displayValue = (duration.inMinutes / 30).clamp(0.0, 8.0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: List.generate(displayValue.ceil(), (index) {
        if (index == 0) {
          return _buildBlock(displayValue >= 5.0 ? 1.0 : displayValue % 1.0);
        } else {
          return _buildBlock(1.0);
        }
      }),
    );
  }

  Widget _buildBlock(double fillFraction) {
    return Container(
      width: 4,
      height: 4,
      margin: const EdgeInsets.all(1.0),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: FractionallySizedBox(
          widthFactor: fillFraction,
          heightFactor: 1.0,
          child: Container(
            color: Colors.accents.first,
          ),
        ),
      ),
    );
  }
}

class DurationText extends StatelessWidget {
  const DurationText({required this.duration, super.key});

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
