import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import '../util/duration_widget.dart';

import 'bloc.dart';
import 'scheduled_event.dart';
import '../priority/bloc.dart';

final supabase = Supabase.instance.client;

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, scheduleState) => Padding(
        padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 70,
              padding: const EdgeInsets.only(right: 8),
              alignment: Alignment.centerRight,
              child: Text.rich(
                TextSpan(
                  children: <TextSpan>[
                    TextSpan(
                      text: event.at.start.clockString,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: event.at.start.meridiem,
                      style: const TextStyle(
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            BlocBuilder<PrioritiesBloc, PrioritiesState>(
              builder: (context, prioritiesState) => Expanded(
                child: MenuAnchor(
                  builder: (BuildContext context, MenuController controller,
                          Widget? child) =>
                      InkWell(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.activity?.name ?? 'Open',
                        ),
                        if (event.name != null)
                          Text(
                            event.name!,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                      ],
                    ),
                    onTap: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    },
                  ),
                  menuChildren: [
                    if (event.id != null &&
                        event.at.end.isAfter(DateTime.now()))
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.event_busy),
                        onPressed: () {
                          context.read<ScheduleBloc>().add(ScheduleUpdated(
                                event.copyWith(
                                    response: EventResponse.declined),
                                replace: event,
                              ));
                        },
                        child: const Text('Release time'),
                      ),
                    if (prioritiesState is PrioritiesLoaded)
                      ...prioritiesState.priorities.map(
                        (priority) => MenuItemButton(
                          onPressed: () {
                            context.read<ScheduleBloc>().add(ScheduleUpdated(
                                  event.copyWith(activity: priority.activity),
                                  replace: event,
                                ));
                          },
                          child: Text(priority.activity.name),
                        ),
                      )
                  ],
                ),
              ),
            ),
            Container(
                width: 70,
                padding: const EdgeInsets.only(left: 8, right: 4),
                alignment: Alignment.centerRight,
                child: DurationWidget(
                  duration: event.at.duration,
                )),
          ],
        ),
      ),
    );
  }
}
