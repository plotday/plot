import 'package:flutter/material.dart';

import 'activity.dart';

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Create a list from Activity.list()
    return FutureBuilder<List<Activity>>(
      future: Activity.list(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final activities = snapshot.data!;
          return ListView.builder(
            itemCount: activities.length,
            itemBuilder: (context, index) {
              final activity = activities[index];
              return ListTile(
                title: Text(activity.name),
                // subtitle: Text(activity.description),
                // trailing: Text(activity.priority.toString()),
              );
            },
          );
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}
