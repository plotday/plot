import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/now.dart';
import 'package:plot/util/time.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/platform/spinner.dart';

class EventPage extends StatelessWidget {
  const EventPage({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, state) {
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

class EventPageLoader extends StatefulWidget {
  const EventPageLoader({this.eventId, super.key});

  final int? eventId;

  @override
  State<EventPageLoader> createState() => EventPageLoaderState();
}

class EventPageLoaderState extends State<EventPageLoader> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EventPageLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.eventId != oldWidget.eventId) {
      _load();
    }
  }

  void _load() {
    if (widget.eventId == null) {
      _eventLoading = context.read<NowBloc>().selectCurrent();
    } else {
      _eventLoading = context.read<NowBloc>().selectById(widget.eventId!);
    }
  }

  late Future<void> _eventLoading;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, state) {
      return FutureBuilder(
        future: _eventLoading,
        builder: (context, snapshot) {
          if (!snapshot.hasData || state is! SelectedEventState) {
            return const Center(child: Spinner());
          }
          return EventPage(event: state.selected);
        },
      );
    });
  }
}
