import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/input_action.dart';

class ActivityEditPage extends StatelessWidget {
  const ActivityEditPage({this.activityId, this.parentId, super.key});

  final ActivityId? activityId;
  final ActivityId? parentId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Column(
        children: [
          InputAction(
            onAdd: (name) {
              Activity(
                name: name,
                parent: state.current,
                order: Order.between(state.children.lastOrNull?.order, null),
              ).save();
            },
            label: "Add an actvity",
          ),
        ],
      ),
    );
  }
}
