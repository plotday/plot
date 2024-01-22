import 'package:flutter/material.dart';

import 'scheduled_event.dart';

class ScheduledEventWidget extends StatelessWidget {
  const ScheduledEventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(event.name),
    );
  }
}
