import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/model/schedule.dart';
import 'package:plot/state/now.dart';
import 'package:plot/util/time.dart';

class EventPage extends StatelessWidget {
  const EventPage({this.event, super.key});

  final ScheduledEvent? event;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, state) {
      final event = this.event ?? state.current;
      return Column(children: [
        const Text('Event Page'),
        if (event.name != null) Text(event.name!),
        Text(event.at.start.toDate().format()),
        Text(event.at.start.toTimeOfDay().format(context)),
        Text(event.at.end.toTimeOfDay().format(context)),
      ]);
    });
  }
}
