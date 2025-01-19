import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

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
  final void Function(Priority?) onSelect;

  @override
  PrioritySelectorState createState() => PrioritySelectorState();
}

class PrioritySelectorState extends State<PrioritySelector> {
  @override
  Widget build(BuildContext context) {
    return Tapable(
      onTap: () {
        context.run(ChangePriority());
      },
      child: Wrap(
        spacing: 4,
        children: [
          ...[null, if (widget.selected != null) ...widget.selected!.ancestry]
              .map((a) => Text(a?.name ?? 'Everything'))
              .toList()
              .expand((widget) => [
                    widget,
                    const PlotIcon.right(size: 14, color: material.Colors.grey)
                  ])
              .toList()
            ..removeLast()
        ],
      ),
    );
  }
}
