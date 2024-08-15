import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/context.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class Header extends StatelessWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ContextBloc, ContextState>(
      builder: (buildContext, state) => Row(
        children: [
          if (state.current != null)
            IconButton(
              icon: const BackButtonIcon(),
              onPressed: () {
                state.current?.parent == null
                    ? PrioritiesRoute().go(context)
                    : PriorityRoute(
                            contextId: state.current!.parent!.id!.toString())
                        .go(context);
              },
            ),
          Expanded(
            child: Text(
              state.current?.name ?? 'Everything else',
              overflow: TextOverflow.ellipsis,
            ),
          )
        ],
      ),
    );
  }
}
