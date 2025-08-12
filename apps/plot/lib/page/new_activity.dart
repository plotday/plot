import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/hooks.dart';

class NewActivityPage extends HookWidget {
  const NewActivityPage({
    required this.priorityId,
    Activity? parent,
    super.key,
  }) : _initialParent = parent;

  final PriorityId priorityId;
  final Activity? _initialParent;

  @override
  Widget build(BuildContext context) {
    final (noteController, note) = useTextEditingValue();
    final parent = useState<Activity?>(_initialParent);
    final priority = Priority.getOne(priorityId);

    return Dialog(
      header: Header(
        main: Row(
          children: [
            Text('New activity'),
            if (parent.value != null) ...[
              Text(' in '),
              Text(parent.value!.displayTitle),
            ],
          ],
        ),
        modal: true,
      ),
      builder: (context) => Column(
        spacing: 16,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: noteController,
            label: "Add an activity",
            maxLines: 3,
            autofocus: true,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Button.primary(
                CommandWrapper(
                  AddActivity(
                    priority.then((p) => Activity(
                      priority: p,
                      note: note,
                      parent: parent.value,
                      order: Order.first(),
                    )),
                  ),
                  run: (command, context) async {
                    final ret = command.run(context);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return ret;
                  },
                ),
                enabled: note.isNotEmpty,
              ),
            ],
          ),
        ],
      ),
    );
  }
}