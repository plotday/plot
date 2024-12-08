import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/page/new_topic.dart';
import 'package:plot/page/new_activity.dart';

enum NewType {
  topic,
  activity,
}

class NewPage extends StatefulWidget {
  const NewPage({super.key});

  @override
  NewPageState createState() => NewPageState();
}

class NewPageState extends State<NewPage> {
  NewType selected = NewType.topic;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Toggle(
              choices: const [
                ToggleChoice(value: NewType.topic, label: 'Topic'),
                ToggleChoice(value: NewType.activity, label: 'Activity'),
              ],
              selected: selected,
              onSelect: (choice) {
                setState(() {
                  selected = choice;
                });
              },
            ),
            const SizedBox(height: 8),
            if (selected == NewType.topic) const NewTopic(),
            if (selected == NewType.activity) const NewActivity(),
          ],
        ),
      ),
    );
  }
}
