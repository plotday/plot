import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/hooks.dart';

class NewPriorityPage extends HookWidget {
  const NewPriorityPage({Priority? parent, super.key})
    : _initialParent = parent;

  final Priority? _initialParent;

  @override
  Widget build(BuildContext context) {
    final (nameController, title) = useTextEditingValue();
    final parent = useState<Priority?>(_initialParent);

    return Dialog(
      header: Header(
        main: Row(
          children: [
            Text('New priority in '),
            PrioritySelector(
              selected: parent.value,
              onSelect: (priority) {
                parent.value = priority;
              },
            ),
          ],
        ),
        modal: true,
      ),
      builder: (context) => Column(
        spacing: 16,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            label: "Add a priority",
            maxLines: 1,
            autofocus: true,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Button.primary(
                CommandWrapper(
                  AddPriority(
                    Future.value(
                      Priority(
                        title: title,
                        parent: parent.value,
                        order: Order.first(),
                      ),
                    ),
                  ),
                  run: (command, context) async {
                    final ret = command.run(context);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return ret;
                  },
                ),
                enabled: title.isNotEmpty,
              ),
            ],
          ),
        ],
      ),
      // ),
    );
  }
}
