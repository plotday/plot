import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/cached_reorderable_list_view.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/model/priority.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/platform/scaffold.dart';
import 'package:plot/platform/spinner.dart';

class WeekNavigatorWidget extends StatelessWidget {
  const WeekNavigatorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final week = context.watch<PriorityBloc>().state.week;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      material.IconButton(
          icon: const Icon(material.Icons.chevron_left),
          onPressed: () {
            context.read<PriorityBloc>().setWeek(week.previous());
          }),
      Text(week.format()),
      material.IconButton(
          icon: const Icon(material.Icons.chevron_right),
          onPressed: () {
            context.read<PriorityBloc>().setWeek(week.next());
          }),
    ]);
  }
}

class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, prioritiesState) => Scaffold(
        // appBar: AppBar(title: const WeekNavigatorWidget()),
        // floatingActionButton: material.FloatingActionButton(
        //   onPressed: () {
        //     context.push('/new');
        //   },
        //   child: const Icon(material.Icons.add),
        // ),
        body: Builder(builder: (BuildContext context) {
          switch (prioritiesState) {
            case PriorityLoading _:
              return const Spinner();
            case PriorityLoaded _:
              return CachedReorderableListView(
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                  Priority? previous;
                  if (previousIndex >= 0) {
                    previous = prioritiesState.priorities[previousIndex];
                  }
                  Priority? next;
                  if (nextIndex < prioritiesState.priorities.length) {
                    next = prioritiesState.priorities[nextIndex];
                  }
                  final priority = prioritiesState.priorities[oldIndex]
                      .copyWith(after: previous, before: next);
                  context.read<PriorityBloc>().updatePriority(priority);
                },
                list: prioritiesState.priorities,
                itemBuilder: (context, priority) {
                  return BlocProvider.value(
                    key: ValueKey(priority.key),
                    value: BlocProvider.of<NowBloc>(context),
                    child: PriorityWidget(priority: priority),
                  );
                },
              );
          }
        }),
      ),
    );
  }
}
