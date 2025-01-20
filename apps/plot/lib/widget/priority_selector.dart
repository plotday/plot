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
      child: PriorityLabel(priority: widget.selected),
    );
  }
}
