import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/widget/event_details.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/store/store.dart';

@RoutePage()
class EventPage extends StatelessWidget {
  EventPage({
    Event? event,
    EventId? eventId,
    @PathParam("eventId") String? eventIdString,
    @QueryParam() String? at,
    super.key,
  })  : eventId = (event?.unsaved == false ? event?.id : null) ??
            eventId ??
            (eventIdString != null
                ? Uuid.fromShortString(eventIdString)
                : null),
        at = event?.at ?? (at != null ? DateTimeRange.fromString(at) : null);

  final EventId? eventId;
  final DateTimeRange? at;

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
