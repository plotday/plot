import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../util/api.dart' as api;
import '../util/time.dart';

import '../now/bloc.dart';
import 'scheduled_event.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEventMenu extends StatelessWidget {
  const ScheduledEventMenu({required this.event, super.key});

  final ScheduledEvent event;

  Future<void> _rsvp(EventResponse response) async {
    await api.put(
      "/event/${event.id}/rsvp",
      body: {
        'response': response.name,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
        builder: (context, state) => MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                  Widget? child) {
                return Row(
                  children: [
                    if (event.at.end.isAfter(DateTime.now()))
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => {_rsvp(EventResponse.declined)},
                        tooltip: 'Remove',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                      ),
                    IconButton(
                      onPressed: () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                      icon: const Icon(Icons.more_horiz),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Show menu',
                    )
                  ],
                );
              },
              menuChildren: [
                if (event.at.isNow())
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.add),
                    child: const Text('More time'),
                    onPressed: () {
                      context.read<NowBloc>().add(ActivityTimeIncreased());
                    },
                  ),
                if (event.at.isNow())
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.remove),
                    child: const Text('Less time'),
                    onPressed: () {
                      context.read<NowBloc>().add(ActivityTimeDecreased());
                    },
                  ),
              ],
            ));
  }
}
