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
            twists: state.twists,
            onSubmitted: (body, {bool alt = false}) async {
              log.info('Adding new activity with body: $body ($alt)');

              // Parse mentions from the note (stored as [#@ID])
              final mentions = Activity.parseMentionsFromNote(
                body,
                state.twists,
              );

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
              // =======
              //           builder: (context, focusNode) => FutureBuilder<List<Account>>(
              //             future: Account.get(),
              //             builder: (context, snapshot) {
              //               // Get list of user emails for mentions
              //               final users = snapshot.data?.map((account) => account.email).toList() ?? [];
              //
              //               return Editor(
              //                 hint: 'Add activity',
              //                 autofocus: true,
              //                 focusNode: focusNode,
              //                 users: users,
              //                 onSubmitted: (body, {bool alt = false}) async {
              //                   log.info(
              //                     'Adding new activity with body: $body ($alt)',
              //                   );
              //                   final activity = state.draft.copyWith(
              //                     note: Value(body),
              //                     draft: false,
              //                     doAt: alt
              //                         ? Value(Date.today())
              //                         : const Value.absent(),
              //                   );
              //                   await context.read<PriorityBloc>().add(activity);
              //                 },
              //               );
              // >>>>>>> 1783849 (Editor mentions (wip))
            },
          ),
        );
      },
    );
  }
}
