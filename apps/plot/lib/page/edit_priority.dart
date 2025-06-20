import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/hooks.dart';

class EditPriorityPage extends HookWidget {
  const EditPriorityPage({Priority? parent, Priority? priority, super.key})
    : _initialParent = parent,
      _priority = priority;

  final Priority? _initialParent;
  final Priority? _priority;

  bool get isEditing => _priority != null;

  @override
  Widget build(BuildContext context) {
    final (nameController, title) = useTextEditingValue(initialValue: _priority?.title ?? '');
    final parent = useState<Priority?>(_initialParent);

    Future<void> submitPriority() async {
      if (title.isEmpty) return;

      if (isEditing) {
        // Edit existing priority
        final command = EditPriority(
          Future.value(_priority!.copyWith(title: title)),
        );
        await command.run(context);
      } else {
        // Create new priority
        final command = AddPriority(
          Future.value(
            Priority(title: title, parent: parent.value, order: Order.first()),
          ),
        );
        await command.run(context);
      }

      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }

    final fieldLabel = isEditing ? "Edit priority" : "Add a priority";

    return Column(
      spacing: 16,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: nameController,
          label: fieldLabel,
          maxLines: 1,
          autofocus: true,
          onSubmitted: (_) => submitPriority(),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Button.primary(
              CommandWrapper(
                isEditing 
                  ? EditPriority(
                      Future.value(_priority!.copyWith(title: title)),
                    )
                  : AddPriority(
                      Future.value(
                        Priority(
                          title: title,
                          parent: parent.value,
                          order: Order.first(),
                        ),
                      ),
                    ),
                run: (command, context) async {
                  await submitPriority();
                  return null;
                },
              ),
              enabled: title.isNotEmpty,
            ),
          ],
        ),
      ],
    );
  }
}
