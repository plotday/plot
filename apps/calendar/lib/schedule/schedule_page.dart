import 'package:flutter/material.dart';

import 'scheduled_event.dart';
import '../util/time.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder(
        future: ScheduledEvent.list(Time.today()),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView.builder(
            itemCount: snapshot.data!.length,
            itemBuilder: (context, index) {
              final event = snapshot.data![index];
              return ListTile(
                title: Text(event.name),
              );
            },
          );
        },
      ),
    );
  }
}
