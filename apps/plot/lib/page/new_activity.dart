import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

enum NewType {
  topic,
  activity,
}

class NewActivity extends StatelessWidget {
  const NewActivity({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InputAction(
              onAdd: (name) {
                Activity(
                  name: name,
                  parent: state.current,
                  order: Order.between(state.children.lastOrNull?.order, null),
                ).save();
              },
              label: "Add an activity",
            ),
          ],
        ),
      ),
    );
  }
}
