import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/widget/schedule.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule'),
      ),
      body: BlocProvider(
        create: (context) => ScheduleBloc(),
        child: Column(children: [Expanded(child: ScheduleWidget())]),
      ),
    );
  }
}
