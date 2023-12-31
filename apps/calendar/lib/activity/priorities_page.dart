import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'activity.dart';
import 'bloc.dart';

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Activity>>(
      future: Activity.list(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          final activities = snapshot.data!;
          return BlocBuilder<ActivityBloc, ActivityState>(
              builder: (context, activityState) => ListView.builder(
                    itemCount: activities.length,
                    itemBuilder: (context, index) {
                      final activity = activities[index];
                      return ListTile(
                          title: TextButton(
                        onPressed: () {
                          context
                              .read<ActivityBloc>()
                              .add(ActivitySelected(activity));
                        },
                        child: Text(activity.name),
                      ));
                    },
                  ));
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }
}
