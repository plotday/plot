import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/widget/time.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({required this.activity, this.balances, super.key});
  final Activity activity;
  final BalanceByType? balances;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => ActivityRoute.byId(activity.id).go(context),
      key: ValueKey(activity.id.toString()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(activity.name),
            if (balances != null)
              Row(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 2.0),
                        child: Icon(material.Icons.hourglass_bottom, size: 14),
                      ),
                      DurationText(
                          duration: balances![BalanceType.accepted]?.time ??
                              Duration.zero),
                      Text("(${(balances![BalanceType.do_now]?.count ?? 0)})"),
                    ],
                  ),
                  const SizedBox(width: 8),
                  // Row(
                  //   crossAxisAlignment: CrossAxisAlignment.center,
                  //   children: [
                  //     const Padding(
                  //       padding: EdgeInsets.only(bottom: 2.0),
                  //       child: Icon(material.Icons.hourglass_top, size: 14),
                  //     ),
                  //     DurationText(duration: balance!.budget)
                  //   ],
                  // )
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
      ),
    );
  }
}
