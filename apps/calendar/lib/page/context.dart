import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/reorderable_list_view.dart';
import 'package:plot/state/context.dart';
import 'package:plot/model/context.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/input_action.dart';

class ContextPage extends StatelessWidget {
  const ContextPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Scaffold(
        body: Column(
          children: [
            ReorderableListView(
              list: state.children,
              itemBuilder: (buildContext, item) =>
                  PriorityWidget(context: item),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Context? previous;
                if (previousIndex >= 0) {
                  previous = state.children[previousIndex];
                }
                Context? next;
                if (nextIndex < state.children.length) {
                  next = state.children[nextIndex];
                }
                final context = state.children[oldIndex].copyWith(
                  order: ContextOrder(previous, next),
                );
                buildContext.read<ContextBloc>().update(context);
              },
            ),
            InputAction(
              onAdd: (name) {
                context.read<ContextBloc>().add(Context(
                      name: name,
                      parent: state.current,
                      order: ContextOrder(state.children.lastOrNull, null),
                    ));
              },
              label: "Add a priority",
            ),
          ],
        ),
      ),
    );
  }
}
