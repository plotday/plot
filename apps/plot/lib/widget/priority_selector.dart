import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class PrioritySelector extends StatefulWidget {
  const PrioritySelector({
    required this.priorities,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final Priority? selected;
  final List<Priority> priorities;
  final void Function(Priority) onSelect;

  @override
  PrioritySelectorState createState() => PrioritySelectorState();
}

class PrioritySelectorState extends State<PrioritySelector> {
  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 4,
      children: [
        Tapable(
          onTap: () {
            context.run<void>(ChangePriority());
          },
          child: PriorityLabel(priority: widget.selected),
        ),
        IconButton(
          icon: const PlotIcon.add(),
          onPressed: () {
            context.run<void>(NewPriority());
          },
        )
      ],
    );
  }
}
