import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity.dart';

class TopicWidget extends StatelessWidget {
  const TopicWidget({
    required this.note,
    super.key,
  });

  final Note note;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => ListTile(
        onTap: () => TopicRoute.byId(note.activityId, note.topicId).go(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            children: [
              if (note.pinned)
                Button(
                  onTap: () =>
                      context.read<ActivityBloc>().updateNote(note.copyWith(
                            pinned: false,
                            order: Order.first(),
                          )),
                  child: const Text('p'),
                ),
              if (note.doNow)
                Button(
                  onTap: () =>
                      context.read<ActivityBloc>().updateNote(note.copyWith(
                            doneAt: Value(DateTime.now()),
                            order: Order.first(),
                          )),
                  child: const Text('d'),
                ),
              if (note.done) const Text('done'),
              Expanded(
                child: Text(note.body),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
