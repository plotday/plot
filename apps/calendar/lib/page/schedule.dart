import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/schedule.dart';
import 'package:plot/widget/schedule.dart';
import 'package:plot/platform/scaffold.dart';

class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BlocProvider(
        create: (context) => ScheduleBloc(),
        child: Expanded(child: ScheduleWidget()),
      ),
    );
  }
}
