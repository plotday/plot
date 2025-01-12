import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';

class NewPriority extends StatelessWidget {
  const NewPriority({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InputAction(
              onAdd: (name) {
                Priority(
                  name: name,
                  parent: state.current,
                  order: Order.between(state.children.lastOrNull?.order, null),
                ).save();
              },
              label: "Add an priority",
            ),
          ],
        ),
      ),
    );
  }
}
