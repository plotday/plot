import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../time/time_bloc.dart';

class PomodoroTimer extends StatelessWidget {
  final int? remainingMinutes;
  final DateTime? next;

  const PomodoroTimer({super.key, this.remainingMinutes, this.next});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TimeBloc, TimeState>(
      builder: (context, state) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CircularProgressIndicator(
                      value: 0.92,
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        if (state is TimeProgress)
                          Text(
                            state.duration.toString(),
                            style: Theme.of(context).textTheme.displaySmall,
                          ),
                        ElevatedButton(
                          onPressed: () {
                            context.read<TimeBloc>().add(const TimeStarted());
                          },
                          child: const Text('Start'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
