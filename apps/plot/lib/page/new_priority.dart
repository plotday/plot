import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/hooks.dart';

class NewPriorityPage extends HookWidget {
  NewPriorityPage({Priority? parent, PriorityId? parentId, super.key})
    : priorityId = parent?.id ?? parentId;

  final PriorityId? priorityId;

  @override
  Widget build(BuildContext context) {
    final (nameController, name) = useTextEditingValue();

    return Scaffold(
      header: Header(title: 'New Priority', modal: true),
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
                    AddPriority(
                      (priorityId == null
                              ? Future<Priority?>.value(null)
                              : Priority.get(priorityId!))
                          .then(
                            (priority) => Priority(
                              name: name,
                              parent: priority,
                              order: Order.first(),
                            ),
                          ),
                    ),
                    enabled: name.isNotEmpty,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
