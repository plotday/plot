import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'activity.dart';
import 'bloc.dart';

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
    final activities = Activity.list();
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, activityState) => Scaffold(
        appBar: AppBar(
          title: Text(activityState.selected?.name ?? 'Priorities'),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => const NewPriorityModal(),
            );
          },
          child: const Icon(Icons.add),
        ),
        body: ListView.builder(
            itemCount: activities.length,
            itemBuilder: (context, index) {
              final activity = activities[index];
              return ListTile(
                  title: TextButton(
                onPressed: () {
                  context.read<ActivityBloc>().add(ActivitySelected(activity));
                },
                child: Text(activity.name),
              ));
            }),
      ),
    );
  }
}
