import 'package:flutter/material.dart';

import '../util/api.dart' as api;

import 'scheduled_event.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

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
    return Card(
        child: ListTile(
      title: Text(event.name),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () {
          _rsvp(EventResponse.declined);
        },
      ),
    ));
  }
}
