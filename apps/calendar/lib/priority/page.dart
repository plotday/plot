import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'activity.dart';
import 'budget.dart';
import 'bloc.dart';
import '../now/bloc.dart';
import '../util/time.dart';
import '../util/cached_reorderable_list_view.dart';

class NewPriorityModal extends StatefulWidget {
  const NewPriorityModal({super.key});

  @override
  State<NewPriorityModal> createState() => _NewPriorityModalState();
}

class _NewPriorityModalState extends State<NewPriorityModal> {
  Activity? parent;

  @override
  Widget build(BuildContext context) {
    final TextEditingController activityController = TextEditingController();
    return Dialog(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: activityController,
              decoration: const InputDecoration(
                labelText: 'New priority',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 24),
            DropdownMenu<Activity?>(
              label: const Text('Parent'),
              initialSelection: parent,
              onSelected: (Activity? newValue) {
                setState(() {
                  parent = newValue;
                });
              },
              dropdownMenuEntries: [
                    const DropdownMenuEntry<Activity?>(
                      value: null,
                      label: 'None',
                    )
                  ] +
                  Activity.list().map<DropdownMenuEntry<Activity?>>((activity) {
                    return DropdownMenuEntry<Activity?>(
                      value: activity,
                      label: activity.name,
                    );
                  }).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  child: const Text('Add'),
                  onPressed: () async {
                    context.read<PrioritiesBloc>().add(
                        PriorityAdded(activityController.text, parent: parent));
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({required this.priority, super.key});
  final Budget priority;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey(priority.activity.id.toString()),
      onTap: () {
        context.read<NowBloc>().add(ActivitySelected(priority.activity));
      },
      isThreeLine: true,
      title: Text(priority.activity.name),
      subtitle: const Column(children: [
        LinearProgressIndicator(value: 0.3),
        Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text('0:30'), Text('2:30')])
      ]),
      selected:
          priority.activity.id == context.watch<NowBloc>().state.selected?.id,
    );
  }
}

class WeekNavigatorWidget extends StatelessWidget {
  const WeekNavigatorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final week = context.watch<PrioritiesBloc>().state.week;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            context
                .read<PrioritiesBloc>()
                .add(PrioritiesWeekChanged(week.previous));
          }),
      Text(week.friendly),
      IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            context
                .read<PrioritiesBloc>()
                .add(PrioritiesWeekChanged(week.next));
          }),
    ]);
  }
}

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, prioritiesState) => Scaffold(
        appBar: AppBar(title: const WeekNavigatorWidget()),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            showDialog(
                context: context,
                builder: (_) => BlocProvider.value(
                      value: BlocProvider.of<PrioritiesBloc>(context),
                      child: const NewPriorityModal(),
                    ));
          },
          child: const Icon(Icons.add),
        ),
        body: Builder(builder: (BuildContext context) {
          switch (prioritiesState) {
            case PrioritiesLoading _:
              return const CircularProgressIndicator();
            case PrioritiesLoaded _:
              return CachedReorderableListView(
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                  Budget? previous;
                  if (previousIndex >= 0) {
                    previous = prioritiesState.priorities[previousIndex];
                  }
                  Budget? next;
                  if (nextIndex < prioritiesState.priorities.length) {
                    next = prioritiesState.priorities[nextIndex];
                  }
                  final budget = prioritiesState.priorities[oldIndex]
                      .copyWith(after: previous, before: next);
                  context.read<PrioritiesBloc>().add(PriorityChanged(budget));
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
