import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/time.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/model/priority.dart';

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({required this.priority, super.key});
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey(priority.context?.id.toString() ?? 0),
      onTap: () {
        if (priority.context == null) {
          return;
        }
        context.read<NowBloc>().setContext(priority.context);
      },
      title: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(priority.context?.name ?? 'Everything else'),
        Row(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.only(
                      bottom: 2.0), // Add 2px padding at the bottom
                  child: Icon(Icons.hourglass_bottom, size: 14),
                ),
                DurationWidget(duration: priority.scheduled),
              ],
            ),
            const SizedBox(width: 8),
            MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                      Widget? child) =>
                  InkWell(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(
                          bottom: 2.0), // Add 2px padding at the bottom
                      child: Icon(Icons.hourglass_top, size: 14),
                    ),
                    DurationWidget(duration: priority.budget)
                  ],
                ),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              ),
              menuChildren: [
                for (var m = 0; m <= 120; m += 15)
                  MenuItemButton(
                    onPressed: () {
                      context.read<PriorityBloc>().add(PriorityChanged(
                          priority.copyWith(budget: Duration(minutes: m))));
                    },
                    child: m == 0
                        ? const Text('Done')
                        : DurationWidget(duration: Duration(minutes: m)),
                  ),
              ],
            ),
          ],
        ),
      ]),
      subtitle: LinearProgressIndicator(
          value: priority.budget.inMinutes > 0
              ? priority.scheduled.inMinutes / priority.budget.inMinutes
              : 0),
      selected:
          priority.context?.id == context.watch<NowBloc>().state.context?.id,
    );
  }
}
