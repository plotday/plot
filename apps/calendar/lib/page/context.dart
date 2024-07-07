import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/cached_reorderable_list_view.dart';
import 'package:plot/state/context.dart';
import 'package:plot/state/now.dart';
import 'package:plot/model/context.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/input_action.dart';

class ContextHeader extends StatelessWidget {
  const ContextHeader({this.context, super.key});

  final Context? context;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(this.context?.name ?? 'Everything else'),
    ]);
  }
}

class ContextPage extends StatelessWidget {
  const ContextPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Column(
        children: [
          ...state.children.map((context) => ContextHeader(context: context)),
          InputAction(
            onAdd: (name) {
              context.read<ContextBloc>().add(Context(name: name));
            },
            label: "Add a priority",
          ),
        ],
      ),
    );
  }
}
