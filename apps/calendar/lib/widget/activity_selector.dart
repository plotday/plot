import 'package:flutter/widgets.dart';

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
    return Row(
      children: [
        ...[null, if (selected != null) ...selected!.ancestry]
            .map((a) => Tapable(
                  onTap: () {
                    onSelect(a);
                  },
                  child: Text(a?.name ?? 'Home'),
                ))
            .toList()
            .expand((widget) => [widget, const PlotIcon.right()])
            .toList()
          ..removeLast()
      ],
    );
  }
}
