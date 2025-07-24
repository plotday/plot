import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

class ActivityEditor extends StatelessWidget {
  const ActivityEditor({
    required this.onAdd,
    required this.draft,
    super.key,
  });

  final Future<void> Function(Activity activity) onAdd;
  final Activity draft;

  @override
  Widget build(BuildContext context) {
    return EditableArea(
      position: EditableAreaPosition.bottom,
      builder: (context, focusNode) => Editor(
        hint: 'Add activity',
        autofocus: true,
        focusNode: focusNode,
        onSubmitted: (body, {bool alt = false}) async {
          log.info('Adding new activity with body: $body ($alt)');
          final activity = draft.copyWith(
            note: Value(body),
            draft: false,
            doAt: alt ? Value(Date.today()) : const Value.absent(),
          );
          await onAdd(activity);
        },
      ),
    );
  }
}

