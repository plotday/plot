import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ActivitySelector extends StatelessWidget {
  const ActivitySelector({
    required this.selected,
    required this.onSelect,
    super.key,
  });

  final Activity? selected;
  final void Function(Activity?) onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      children: [
        ...[null, if (selected != null) ...selected!.ancestry]
            .map((a) => Tapable(
                  onTap: () {
                    onSelect(a);
                  },
                  child: Text(a?.name ?? 'Home'),
                ))
            .toList()
            .expand((widget) => [
                  widget,
                  const PlotIcon.right(size: 14, color: material.Colors.grey)
                ])
            .toList()
          ..removeLast()
      ],
    );
  }
}
