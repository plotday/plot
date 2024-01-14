import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'activity.dart';
import 'budget.dart';
import 'bloc.dart';
import '../now/bloc.dart';

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
                    await Activity.add(activityController.text, parent);
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

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, prioritiesState) => Scaffold(
          appBar: AppBar(title: const Text("Priorities")),
          floatingActionButton: FloatingActionButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => const NewPriorityModal(),
              );
            },
            child: const Icon(Icons.add),
          ),
          body: Builder(builder: (BuildContext context) {
            switch (prioritiesState) {
              case PrioritiesLoading _:
                return const CircularProgressIndicator();
              case PrioritiesLoaded _:
                return ReorderableListView.builder(
                    onReorder: (int oldIndex, int newIndex) async {
                      Budget? before;
                      if (newIndex > 0) {
                        before = prioritiesState.priorities[newIndex - 1];
                      }
                      Budget? after;
                      if (newIndex < prioritiesState.priorities.length - 1) {
                        after = prioritiesState.priorities[newIndex + 1];
                      }
                      final budget = prioritiesState.priorities[oldIndex]
                          .copyWith(before: before, after: after);
                      final hey = await budget.save();
                      print("Hey ${hey.toJson()}");
                    },
                    itemCount: prioritiesState.priorities.length,
                    itemBuilder: (context, index) {
                      final priority = prioritiesState.priorities[index];
                      return ListTile(
                          key: Key(priority.activity.id.toString()),
                          title: TextButton(
                            onPressed: () {
                              context
                                  .read<NowBloc>()
                                  .add(ActivitySelected(priority.activity));
                            },
                            child: Text(priority.activity.name),
                          ));
                    });
            }
          })),
    );
  }
}
