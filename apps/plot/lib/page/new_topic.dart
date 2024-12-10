import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';

class NewTopic extends StatelessWidget {
  const NewTopic({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Column(
        children: [
          Switch(
            value: state.topic.doAt != null,
            onChanged: (on) =>
                context.read<ActivityBloc>().updateNote(state.topic.copyWith(
                      doAt: on ? Value(DateTime.now()) : const Value(null),
                      doneAt: const Value(null),
                      pinned: false,
                    )),
            child: const Text("Do now"),
          ),
          Switch(
            value: state.topic.pinned,
            onChanged: (on) =>
                context.read<ActivityBloc>().updateNote(state.topic.copyWith(
                      pinned: on,
                      doAt: const Value(null),
                    )),
            child: const Text("Pin"),
          ),
          InputAction(
            // TODO update body while editing
            onAdd: (body) async {
              final destination = (state.draft.activityId, state.draft.topicId);
              await context
                  .read<ActivityBloc>()
                  .updateNote(state.draft.copyWith(body: body, draft: false));
              if (context.mounted) {
                TopicRoute.byId(destination.$1, destination.$2).go(context);
              }
            },
            label: "Start a topic",
          ),
        ],
      ),
    );
  }
}
