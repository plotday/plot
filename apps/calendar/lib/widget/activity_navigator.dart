import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class ActivityNavigator extends StatelessWidget {
  const ActivityNavigator({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) => Row(
        children: state.current == null
            ? const [Text('Plot')]
            : [
                ...[null, ...state.current!.ancestry]
                    .map((a) => Tapable(
                          onTap: () {
                            ActivityRoute.byId(a?.id).go(context);
                          },
                          child: Text(a?.name ?? 'Home'),
                        ))
                    .toList()
                    .expand((widget) => [widget, Icons.right])
                    .toList()
                  ..removeLast()
              ],
      ),
    );
  }
}
