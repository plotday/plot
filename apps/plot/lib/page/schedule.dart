import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/widget/event_details.dart';

import 'package:plot/widget/schedule.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/router.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) => Column(
        children: [
          if (state.selected != null)
            EventDetails(
              event: state.selected!,
              onChanged: (event) {
                context.read<ScheduleBloc>().update(event);
              },
            ),
          Expanded(
            child: ScheduleWidget(
              scrollController: ScrollControllerContext.of(context),
              range: state.range,
              anchor: state.anchor,
              schedule: state.schedule,
              selected: state.selected,
              fetcher: (range) async {
                context.read<ScheduleBloc>().watch(range);
              },
              onSelect: (event) {
                if (event.isBlank) {
                  NewEventRoute.at(event.at).go(context);
                } else {
                  EventRoute.byId(event.id).go(context);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleHeader extends StatelessWidget {
  const ScheduleHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) => Header(
        title: 'Schedule',
        actions: [
          HeaderAction(
            icon: const PlotIcon.today(),
            label: 'Schedule',
            showLabel: false,
            onPressed: () {
              ScheduleRoute.day(state.day).go(context);
            },
          ),
        ],
      ),
    );
  }
}
