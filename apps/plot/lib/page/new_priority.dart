import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/widget/widget.dart';

@RoutePage()
class NewPriorityPage extends StatelessWidget {
  NewPriorityPage({
    Priority? priority,
    PriorityId? priorityId,
    @QueryParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId = priority?.id ??
            priorityId ??
            (priorityIdString != null
                ? PriorityId.fromShortString(priorityIdString)
                : null);

  final PriorityId? priorityId;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onSubmitted: (name) async {
                Priority? parent;
                if (priorityId != null) {
                  parent = await Priority.get(priorityId!);
                }
                final priority = Priority(
                  name: name,
                  parent: parent,
                  order: Order.first(),
                );
                await priority.save();
                if (context.mounted) {
                  Navigator.of(context).pop(priority);
                }
              },
              label: "Add an priority",
              maxLines: 1,
              autofocus: true,
            ),
          ],
        ),
      ),
    );
  }
}
