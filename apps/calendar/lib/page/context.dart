import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/cached_reorderable_list_view.dart';
import 'package:plot/state/context.dart';
import 'package:plot/model/context.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/input_action.dart';
import 'package:plot/router.dart';

class ContextHeader extends StatelessWidget {
  const ContextHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Row(
        children: [
          if (state.current != null)
            IconButton(
              child: const BackButtonIcon(),
              onTap: () {
                state.current?.parent == null
                    ? PrioritiesRoute().go(context)
                    : PriorityRoute(contextId: state.current!.parent!.id!)
                        .go(context);
              },
            ),
          Text(state.current?.name ?? 'Everything else'),
        ],
      ),
    );
  }
}

class ContextPage extends StatelessWidget {
  const ContextPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Scaffold(
        title: const ContextHeader(),
        body: Column(
          children: [
            ...state.children
                .map((context) => PriorityWidget(context: context)),
            InputAction(
              onAdd: (name) {
                context
                    .read<ContextBloc>()
                    .add(Context(name: name, parent: state.current));
              },
              label: "Add a priority",
            ),
          ],
        ),
      ),
    );
  }
}
