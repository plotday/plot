import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/now.dart';
import 'package:plot/page/loading.dart';

class NowPage extends StatelessWidget {
  const NowPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocListener<NowBloc, NowState>(
      listener: (context, state) {
        var nowState = context.read<NowBloc>().state;
        if (nowState is NowLoadingState) {
          return;
        }
        nowState = nowState as NowLoadedState;
        final priorityId = nowState.priority.id;
        if (priorityId == null) {
          return const PrioritiesRoute().go(context);
        } else {
          return PriorityRoute.byId(priorityId).go(context);
        }
      },
      child: const LoadingPage(),
    );
  }
}
