import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/widget.dart';

class EventPage extends StatelessWidget {
  const EventPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(builder: (context, state) {
      return switch (state) {
        SelectedEventErrorState _ => const Center(child: Text("Error")),
        SelectedEventState state => Column(children: [
            if (state.selected.name != null) Text(state.selected.name!),
            if (state.selected.activity?.name != null)
              Text(state.selected.activity!.name),
            Text(state.selected.at.start.toDate().format()),
            Text(state.selected.at.start.toTimeOfDay().format(context)),
            Text(state.selected.at.end.toTimeOfDay().format(context)),
          ]),
        SelectedEventLoadingState _ => const Center(child: Spinner()),
        ScheduleState _ => const Center(child: Text("No event selected")),
      };
    });
  }
}
