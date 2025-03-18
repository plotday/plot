import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final Priority? selected;
  final void Function(Priority) onSelect;

  @override
  Widget build(BuildContext context) {
    return Tapable(
      onTap: () async {
        final priority = await PickPriority.recent(
          context,
        ).show(context);
        if (priority != null) {
          onSelect(priority);
        }
      },
      child: PriorityLabel(priority: selected),
    );
  }
}

class PrioritySwitcher extends StatefulWidget {
  const PrioritySwitcher({
    required this.priorities,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final Priority? selected;
  final List<Priority> priorities;
  final void Function(Priority) onSelect;

  @override
  PrioritySwitcherState createState() => PrioritySwitcherState();
}

class PrioritySwitcherState extends State<PrioritySwitcher> {
  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 4,
      children: [
        Tapable(
          onTap: () {
            context.run<void>(PickCurrentActivity());
          },
          child: PriorityLabel(priority: widget.selected),
        ),
        Button.icon(NewPriority())
      ],
    );
  }
}
