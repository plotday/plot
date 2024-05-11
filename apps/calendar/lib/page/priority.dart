import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'package:plot/widget/cached_reorderable_list_view.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/model/priority.dart';
import 'package:plot/widget/priority.dart';

class WeekNavigatorWidget extends StatelessWidget {
  const WeekNavigatorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final week = context.watch<PriorityBloc>().state.week;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            context.read<PriorityBloc>().changeWeek(week.previous());
          }),
      Text(week.format()),
      IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            context.read<PriorityBloc>().changeWeek(week.next());
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
        appBar: AppBar(title: const WeekNavigatorWidget()),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            context.push('/new');
          },
          child: const Icon(Icons.add),
        ),
        body: Builder(builder: (BuildContext context) {
          switch (prioritiesState) {
            case PriorityLoading _:
              return const CircularProgressIndicator();
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
                  context.read<PriorityBloc>().changePriority(priority);
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
