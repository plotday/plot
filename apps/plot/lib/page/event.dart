import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/widget/event_details.dart';

import 'package:plot/state/schedule.dart';

class EventPage extends StatelessWidget {
  const EventPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, state) => Column(
        children: [
          EventDetails(
            event: state.selected!,
            onChanged: (event) {
              context.read<ScheduleBloc>().update(event);
            },
          ),
        ],
      ),
    );
  }
}
