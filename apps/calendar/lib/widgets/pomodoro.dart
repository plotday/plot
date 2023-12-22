import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../time/time_bloc.dart';
import '../clock.dart';

class PomodoroTimer extends StatelessWidget {
  final int? remainingMinutes;
  final DateTime? next;

  const PomodoroTimer({super.key, this.remainingMinutes, this.next});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
        stream: Clock().stream,
        builder: (context, snapshot) => BlocBuilder<TimeBloc, TimeState>(
              builder: (context, state) => ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      children: [
                        Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              if (state is TimeProgress)
                                Text(
                                  state.duration.toString(),
                                  style:
                                      Theme.of(context).textTheme.displaySmall,
                                ),
                              if (state is! TimeProgress)
                                const Icon(
                                  Icons.play_arrow,
                                  size: 48.0,
                                  semanticLabel: 'Start',
                                ),
                              if (next != null)
                                Text(
                                  next!
                                      .difference(DateTime.now())
                                      .inMinutes
                                      .toString(),
                                  style:
                                      Theme.of(context).textTheme.displaySmall,
                                ),
                            ],
                          ),
                        ),
                        Positioned.fill(
                          child: InkResponse(
                            onTap: () {
                              context.read<TimeBloc>().add(const TimeStarted());
                            },
                            child: const CircularProgressIndicator(
                              value: 0.92,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ));
  }
}
