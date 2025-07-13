import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'logging.dart';

class ActivityEditor extends StatelessWidget {
  const ActivityEditor({super.key});

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
              log.info(
                'Adding new activity with body: $body ($alt)',
              );
              final activity = state.draft.copyWith(
                note: Value(body),
                draft: false,
                doAt: alt
                    ? Value(Date.today())
                    : const Value.absent(),
              );
              await context.read<PriorityBloc>().add(activity);
            },
          ),
        );
      },
    );
  }
}