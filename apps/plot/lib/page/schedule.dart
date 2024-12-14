import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/schedule.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/router.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) => Scaffold(
        actions: [
          ActionItem(
            icon: const PlotIcon.today(),
            label: 'Schedule',
            showLabel: false,
            onPressed: () {
              HomeRoute.day(state.day).go(context);
            },
          ),
        ],
        body: ScheduleWidget(
          scrollController: ScrollControllerContext.of(context),
          range: state.range,
          anchor: state.anchor,
          schedule: state.schedule,
          selected: state is SelectedEventState ? state.selected : null,
          fetcher: (range) async {
            context.read<ScheduleBloc>().watch(range);
          },
          onSelect: (event) {
            EventRoute.byId(event.id).go(context);
          },
        ),
      ),
    );
  }
}
