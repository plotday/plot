import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ActivitySelector extends StatefulWidget {
  const ActivitySelector({
    required this.activities,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final Activity? selected;
  final List<Activity> activities;
  final void Function(Activity?) onSelect;

  @override
  ActivitySelectorState createState() => ActivitySelectorState();
}

class ActivitySelectorState extends State<ActivitySelector> {
  final DropdownController _controller = DropdownController();

  @override
  Widget build(BuildContext context) {
    return Dropdown(
      controller: _controller,
      dropdown: Column(
        children: [
          for (final activity in (widget.selected == null
              ? widget.activities
              : widget.selected!.children))
            ListTile(
                onTap: () {
                  widget.onSelect(activity);
                },
                title: Wrap(spacing: 4, children: [
                  if (widget.selected != null)
                    const PlotIcon.right(size: 14, color: material.Colors.grey),
                  Text(activity.name),
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
