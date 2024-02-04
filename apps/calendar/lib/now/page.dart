import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc.dart';
import 'pomodoro_widget.dart';

class NowPage extends StatelessWidget {
  const NowPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, nowState) {
      return Scaffold(
        appBar: AppBar(
          title: Text(nowState.selected?.name ?? ''),
          actions: const [PomodoroWidget()],
        ),
      );
    });
  }
}
