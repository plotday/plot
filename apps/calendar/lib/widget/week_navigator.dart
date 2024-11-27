import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
// import 'package:plot/router.dart';

class WeekNavigator extends StatelessWidget {
  const WeekNavigator({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) => BlocBuilder<ActivityBloc, ActivityState>(
        builder: (context, state) => Row(
          children: [
            IconButton(
              icon: Icons.left,
              onPressed: () {
                // context.read<ScheduleBloc>().setDay();
                context.read<ActivityBloc>().setWeek(state.week.previous());
              },
            ),
            Expanded(
              child: Text(
                state.week.format(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icons.right,
              onPressed: () {
                context.read<ActivityBloc>().setWeek(state.week.next());
              },
            ),
          ],
        ),
      ),
    );
  }
}
