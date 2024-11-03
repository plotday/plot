import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/context.dart';
import 'package:plot/widget/input_action.dart';

class ActivityEditPage extends StatelessWidget {
  const ActivityEditPage({this.contextId, this.parentId, super.key});

  final ContextId? contextId;
  final ContextId? parentId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (context, state) => Column(
        children: [
          InputAction(
            onAdd: (name) {
              Context(
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
