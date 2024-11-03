import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class Header extends StatelessWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (buildContext, state) => Row(
        children: [
          if (state.current != null)
            IconButton(
              icon: const BackButtonIcon(),
              onPressed: () async {
                final parent = state.current!.parent;
                if (!context.mounted) return;
                ActivityRoute.byId(parent?.id).go(context);
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
