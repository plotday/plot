import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/widget/time.dart';
import 'package:plot/model/context.dart';
import 'package:plot/model/budget.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({required this.context, this.budget, super.key});
  final Context context;
  final Budget? budget;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () =>
          PriorityRoute(contextId: this.context.id!.toString()).go(context),
      key: ValueKey(this.context.id.toString()),
      // subtitle: LinearProgressIndicator(
      //     value: priority.budget.inMinutes > 0
      //         ? priority.scheduled.inMinutes / priority.budget.inMinutes
      //         : 0),
      // selected:
      //     priority.context?.id == context.watch<NowBloc>().state.context?.id,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(this.context.name),
          if (budget != null)
            Row(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 2.0),
                      child: Icon(material.Icons.hourglass_bottom, size: 14),
                    ),
                    DurationText(duration: budget!.scheduled),
                  ],
                ),
                const SizedBox(width: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 2.0),
                      child: Icon(material.Icons.hourglass_top, size: 14),
                    ),
                    DurationText(duration: budget!.budget)
                  ],
                )
                // material.MenuAnchor(
                //   builder: (BuildContext context,
                //           material.MenuController controller, Widget? child) =>
                //       material.InkWell(
                //     child: Row(
                //       crossAxisAlignment: CrossAxisAlignment.center,
                //       children: [
                //         const Padding(
                //           padding: EdgeInsets.only(
                //               bottom: 2.0), // Add 2px padding at the bottom
                //           child: Icon(material.Icons.hourglass_top, size: 14),
                //         ),
                //         DurationText(duration: priority.budget)
                //       ],
                //     ),
                //     onTap: () {
                //       if (controller.isOpen) {
                //         controller.close();
                //       } else {
                //         controller.open();
                //       }
                //     },
                //   ),
                //   menuChildren: [
                //     for (var m = 0; m <= 120; m += 15)
                //       material.MenuItemButton(
                //         onPressed: () {
                //           context.read<PriorityBloc>().changePriority(
                //               priority.copyWith(budget: Duration(minutes: m)));
                //         },
                //         child: m == 0
                //             ? const Text('Done')
                //             : DurationText(duration: Duration(minutes: m)),
                //       ),
                //   ],
                // ),
              ],
            ),
        ],
      ),
    );
  }
}
