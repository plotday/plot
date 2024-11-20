import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class ActivityNav extends StatelessWidget {
  const ActivityNav({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (buildContext, state) => Row(
        children: [
          if (state.current != null)
            IconButton(
              icon: Icons.back,
              onPressed: () {
                state.current?.parent == null
                    ? const ActivityRoute.root().go(context)
                    : ActivityRoute.byId(state.current!.parent!.id!)
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
