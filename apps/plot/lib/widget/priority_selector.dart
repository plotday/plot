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
        final priority = await PickPriority.recent(context).show(context);
        if (priority != null) {
          onSelect(priority);
        }
      },
      child: DefaultTextStyle(
        style: DefaultTextStyle.of(
          context,
        ).style.copyWith(color: context.colour.accent),
        child: PriorityLabel(priority: selected),
      ),
    );
  }
}
