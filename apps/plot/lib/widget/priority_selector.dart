import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({required this.selected, this.onSelect, super.key});

  final Priority? selected;
  final void Function(Priority)? onSelect;

  void _onSelect(PriorityId id) async {
    if (onSelect == null) return;
    final priority = await Priority.getOne(id);
    onSelect!(priority);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PriorityLabel(priority: selected, onSelect: _onSelect),
        // TODO: Implement a dialog to select a priority
        // Button(ChangeCurrentPriority()),
        //     final priority = await (PickPriority(
        //       initialPriority: selected,
        //     ).show(context));
        //     if (priority.present) {
        //       onSelect?.call(priority.value);
        //     }
      ],
    );
  }
}
