import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

class ActivityEditor extends StatelessWidget {
  const ActivityEditor({required this.onAdd, required this.draft, super.key});

  final Future<void> Function(Activity activity) onAdd;
  final Activity draft;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return EditableArea(
          position: EditableAreaPosition.bottom,
          builder: (context, focusNode) => Editor(
            hint: 'Add activity',
            autofocus: true,
            focusNode: focusNode,
            onSubmitted: (body, {bool alt = false}) async {
              log.info('Adding new activity with body: $body ($alt)');

              // Parse @mentions from the note
              final mentions = Activity.parseMentionsFromNote(body, state.agents);

              final activity = draft.copyWith(
                note: Value(body),
                draft: false,
                type: alt ? ActivityType.task : draft.type,
                on: alt
                    ? Value(CustomDateRange(Date.today(), null))
                    : const Value.absent(),
                mentions: Value(mentions.isEmpty ? null : mentions),
              );
              await onAdd(activity);
            },
          ),
        );
      },
    );
  }
}
