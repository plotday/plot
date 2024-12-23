import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/widget/widget.dart';

class EventPage extends StatelessWidget {
  const EventPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(builder: (context, state) {
      if (state.selected == null) {
        return const Center(child: Spinner());
      }
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.selected!.activity?.name != null)
              Text(state.selected!.activity!.name),
            Row(
              children: [
                Text(state.selected!.at.start.toDate().format()),
                const SizedBox(width: 8),
                TimeRangePicker(
                  onChanged: (at) {
                    context.read<ScheduleBloc>().update(
                          state.selected!.copyWith(
                            at: at,
                          ),
                        );
                  },
                  value: state.selected!.at,
                ),
              ],
            ),
            TextField(
              label: "Title",
              value: state.selected!.name ?? "",
              onChanged: (name) {
                context.read<ScheduleBloc>().update(
                      state.selected!.copyWith(
                        name: Value(name),
                      ),
                    );
              },
            ),
            Switch(
              label: const Text("Bookable"),
              value: state.selected!.availability == EventAvailability.free,
              onChanged: (free) {
                context.read<ScheduleBloc>().update(
                      state.selected!.copyWith(
                        availability: free
                            ? EventAvailability.free
                            : EventAvailability.busy,
                      ),
                    );
              },
            ),
            Button(
              onTap: () async {
                await context.read<ScheduleBloc>().update(
                    state.selected!.copyWith(deletedAt: Value(DateTime.now())));
                if (!context.mounted) return;
                context.read<ScheduleBloc>().selectCurrent();
              },
              child: const Text("Delete"),
            )
          ],
        ),
      );
    });
  }
}
