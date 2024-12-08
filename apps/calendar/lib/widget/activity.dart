import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class ActivityWidget extends StatelessWidget {
  const ActivityWidget({
    required this.activity,
    this.balances,
    super.key,
    this.onTap,
    this.selected = false,
  });
  final Activity? activity;
  final BalanceByType? balances;
  final VoidCallback? onTap;
  final bool selected;

  Duration get past =>
      (balances?[BalanceType.accepted]?.pastTime ?? Duration.zero) +
      (balances?[BalanceType.session]?.pastTime ?? Duration.zero);
  Duration get future =>
      (balances?[BalanceType.accepted]?.futureTime ?? Duration.zero) +
      (balances?[BalanceType.session]?.futureTime ?? Duration.zero);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () {
        onTap?.call();
      },
      selected: selected,
      key: ValueKey(activity?.id.toString()),
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(activity?.name ?? 'Everything'),
            if (balances != null)
              Row(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (past.isNonZero) DurationText(duration: past),
                      const Text("/"),
                      if (future.isNonZero) DurationText(duration: future),
                      if (balances![BalanceType.todo]?.count != null &&
                          balances![BalanceType.todo]!.count > 0)
                        Badge(count: balances![BalanceType.todo]!.count),
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
