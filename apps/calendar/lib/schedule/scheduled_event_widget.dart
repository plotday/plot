import 'package:flutter/material.dart';

import 'scheduled_event.dart';

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return Card(
        child: ListTile(
      title: Text(event.name),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () {},
      ),
    ));
  }
}
