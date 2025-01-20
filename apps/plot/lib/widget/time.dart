import 'package:flutter/material.dart';

import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/widget.dart';

class SmallCapsWidget extends StatelessWidget {
  const SmallCapsWidget({required this.text, super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final words = text.split(' ');
    return Text.rich(
      TextSpan(
        children: words
            .expand((word) => [
                  TextSpan(
                    text: word[0].toUpperCase(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(
                    text: word.substring(1).toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                    ),
                  ),
                ])
            .toList(),
      ),
    );
  }
}

class TimeWidget extends StatelessWidget {
  const TimeWidget({required this.time, super.key});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final parts = time.toTimeOfDay().formatShort(context).split(' ');
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          height: 1,
        ),
        children: <TextSpan>[
          TextSpan(
            text: parts[0],
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (parts.length > 1)
            const TextSpan(
              text: ' ',
            ),
          if (parts.length > 1)
            TextSpan(
              text: parts[1],
              style: const TextStyle(
                fontSize: 9,
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
    int numBlocks = (duration.inMinutes / 15).ceil().clamp(0, 20);
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: List.generate(numBlocks * 2, (index) {
        if (index % 2 == 0) {
          return Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: const ThemeColor.defaultColor().getForeground(context),
              shape: BoxShape.circle,
            ),
          );
        } else {
          return const SizedBox(width: 4);
        }
      }),
    );
  }
}

class DurationText extends StatelessWidget {
  const DurationText({required this.duration, this.icon, super.key});

  final Duration duration;
  final PlotIcon? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 4,
      children: [
        if (icon != null) icon!,
        Text.rich(
          TextSpan(
            style: const TextStyle(
              fontSize: 12,
              height: 1,
            ),
            children: <TextSpan>[
              if (!duration.hasHours && !duration.hasMinutes)
                const TextSpan(
                  text: '—',
                ),
              if (duration.hasHours)
                TextSpan(
                  text: duration.hoursString,
                ),
              if (duration.hasHours)
                const TextSpan(
                  text: 'h',
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
                  text: 'm',
                  style: TextStyle(fontSize: 10),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
