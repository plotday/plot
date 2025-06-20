import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart' hide Scaffold;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import '../widget/priorities_tree.dart';
import '../widget/scaffold.dart';
import '../widget/header.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      header: Header(
        title: 'Priorities',
        commands: [NewPriority()],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: BlocBuilder<PrioritiesBloc, PrioritiesState>(
          builder: (context, state) {
            return PrioritiesTreeWidget(
              priorities: state.priorities,
              onPrioritySelected: (priority) => _navigateToPriority(context, priority),
            );
          },
        ),
      ),
    );
  }

  void _navigateToPriority(BuildContext context, Priority priority) {
    // Navigate to priority page using the command pattern
    ChangeCurrentPriority(priority).run(context);
  }
}