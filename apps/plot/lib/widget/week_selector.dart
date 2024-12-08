import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/util/time.dart';

class WeekSelector extends StatelessWidget {
  const WeekSelector({required this.week, required this.onSelect, super.key});

  final Week week;
  final void Function(Week) onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const PlotIcon.left(),
          onPressed: () {
            onSelect(week.previous());
          },
        ),
        Expanded(
          child: Text(
            week.format(),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const PlotIcon.right(),
          onPressed: () {
            onSelect(week.next());
          },
        ),
      ],
    );
  }
}
