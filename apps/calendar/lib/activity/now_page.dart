import 'package:flutter/material.dart';

import 'pomodoro_widget.dart';

class NowPage extends StatelessWidget {
  const NowPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
        child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[PomodoroWidget()],
    ));
  }
}
