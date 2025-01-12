import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

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
  final DropdownController _controller = DropdownController();

  @override
  Widget build(BuildContext context) {
    return Dropdown(
      controller: _controller,
      dropdown: Column(
        children: [
          for (final priority in (widget.selected == null
              ? widget.priorities
              : widget.selected!.children))
            ListTile(
                onTap: () {
                  widget.onSelect(priority);
                },
                title: Wrap(spacing: 4, children: [
                  if (widget.selected != null)
                    const PlotIcon.right(size: 14, color: material.Colors.grey),
                  Text(priority.name),
                ])),
        ],
      ),
      child: Wrap(
        spacing: 4,
        children: [
          ...[null, if (widget.selected != null) ...widget.selected!.ancestry]
              .map((a) => Tapable(
                    onTap: () {
                      widget.onSelect(a);
                      _controller.toggle();
                    },
                    child: Text(a?.name ?? 'Everything'),
                  ))
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
