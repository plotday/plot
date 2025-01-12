import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/page/new_activity.dart';
import 'package:plot/page/new_priority.dart';

enum NewType {
  activity,
  priority,
}

class NewPage extends StatefulWidget {
  const NewPage({super.key});

  @override
  NewPageState createState() => NewPageState();
}

class NewPageState extends State<NewPage> {
  NewType selected = NewType.activity;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Toggle(
              choices: const [
                ToggleChoice(value: NewType.activity, label: 'Activity'),
                ToggleChoice(value: NewType.priority, label: 'Priority'),
              ],
              selected: selected,
              onSelect: (choice) {
                setState(() {
                  selected = choice;
                });
              },
            ),
            const SizedBox(height: 8),
            if (selected == NewType.activity) const NewActivity(),
            if (selected == NewType.priority) const NewPriority(),
          ],
        ),
      ),
    );
  }
}
