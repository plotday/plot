import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/widget/time.dart';
import 'package:plot/model/priority.dart';
import 'package:plot/platform/widgets.dart';
import 'package:plot/router.dart';

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({required this.priority, super.key});
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    return Link(
      uri: Uri(path: const SettingsRoute().location),
      child: ListTile(
        key: ValueKey(priority.context?.id.toString() ?? 0),
        // subtitle: LinearProgressIndicator(
        //     value: priority.budget.inMinutes > 0
        //         ? priority.scheduled.inMinutes / priority.budget.inMinutes
        //         : 0),
        // selected:
        //     priority.context?.id == context.watch<NowBloc>().state.context?.id,
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(priority.context?.name ?? 'Everything else'),
          Row(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(
                        bottom: 2.0), // Add 2px padding at the bottom
                    child: Icon(material.Icons.hourglass_bottom, size: 14),
                  ),
                  DurationText(duration: priority.scheduled),
                ],
              ),
              const SizedBox(width: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(
                        bottom: 2.0), // Add 2px padding at the bottom
                    child: Icon(material.Icons.hourglass_top, size: 14),
                  ),
                  DurationText(duration: priority.budget)
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
        ]),
      ),
    );
  }
}
