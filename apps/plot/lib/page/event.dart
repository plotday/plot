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
        SelectedEventState state => Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (state.selected.name != null) Text(state.selected.name!),
                if (state.selected.activity?.name != null)
                  Text(state.selected.activity!.name),
                Row(
                  children: [
                    Text(state.selected.at.start.toDate().format()),
                    const SizedBox(width: 8),
                    TimeRangePicker(
                      onChanged: (at) {
                        context.read<ScheduleBloc>().update(
                              state.selected.copyWith(
                                at: at,
                              ),
                            );
                      },
                      value: state.selected.at,
                    ),
                  ],
                ),
              ],
            ),
          ),
        SelectedEventErrorState _ => const Center(child: Text("Error")),
        SelectedEventLoadingState _ => const Center(child: Spinner()),
        ScheduleState _ => const Center(child: Text("No event selected")),
      };
    });
  }
}
