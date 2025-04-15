import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({
    required this.selected,
    this.onSelect,
    this.onSelectIncludeNone,
    super.key,
  });

  final Priority? selected;
  final void Function(Priority)? onSelect;
  final void Function(Priority?)? onSelectIncludeNone;

  @override
  Widget build(BuildContext context) {
    return Tapable(
      onTap: () async {
        final priority = await (onSelectIncludeNone != null
            ? PickPriorityOrNone(
                initialPriority: selected,
              ).show(context)
            : PickPriority(
                initialPriority: selected,
              ).show(context));
        if (priority.present) {
          if (priority.value != null) {
            onSelect?.call(priority.value!);
          }
          onSelectIncludeNone?.call(priority.value);
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
