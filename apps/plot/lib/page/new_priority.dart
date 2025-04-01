import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/hooks.dart';

@RoutePage()
class NewPriorityPage extends HookWidget {
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
    final (nameController, name) = useTextEditingValue();

    return Scaffold(
      header: Header(
        title: 'New Priority',
      ),
      body: Container(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Column(
            spacing: 16,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                label: "Add an priority",
                maxLines: 1,
                autofocus: true,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Button.primary(
                    AddPriority((priorityId == null
                            ? Future<Priority?>.value(null)
                            : Priority.get(priorityId!))
                        .then(
                      (priority) => Priority(
                        name: name,
                        parent: priority,
                        order: Order.first(),
                      ),
                    )),
                    enabled: name.isNotEmpty,
                  )
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

class AddPriority extends Command {
  AddPriority(this._priority)
      : super(
          title: 'Add',
        );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.copyWith(draft: false).save();
    Posthog().capture(
      eventName: 'Priority Added',
    );
    if (context.mounted) {
      await context.router.replace(PriorityRoute(priorityId: priority.id));
    }
    return null;
  }
}
