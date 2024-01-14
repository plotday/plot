import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc.dart';
import '../schedule/bloc.dart';
import '../util/clock.dart';

String formatDuration(Duration duration, {bool roundUp = false}) {
  final hours = duration.inHours;
  var minutes = duration.inMinutes.remainder(60);
  if (roundUp && duration.inSeconds.remainder(60) > 0) {
    minutes += 1;
  }
  return [hours > 0 ? hours.toString() : '', minutes.toString().padLeft(2, '0')]
      .join(':');
}

class PomodoroWidget extends StatelessWidget implements PreferredSizeWidget {
  const PomodoroWidget({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
        builder: (context, nowState) =>
            BlocBuilder<ScheduleBloc, ScheduleState>(
              builder: (context, scheduleState) => StreamBuilder(
                stream: Clock().seconds,
                builder: (context, snapshot) => AppBar(
                  title: Text(nowState.selected.name),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.remove),
                      tooltip: 'Reduce time',
                      onPressed: () {
                        context.read<NowBloc>().add(ActivityTimeDecreased());
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: 'Add time',
                      onPressed: () {
                        context.read<NowBloc>().add(ActivityTimeIncreased());
                      },
                    ),
                    AspectRatio(
                      aspectRatio: 1,
                      child: Stack(
                        children: [
                          Center(
                              child: FittedBox(
                            fit: BoxFit.fitWidth,
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text(
                                formatDuration(nowState.remaining,
                                    roundUp: true),
                                style: Theme.of(context).textTheme.displaySmall,
                              ),
                            ),
                          )),
                          Positioned.fill(
                            child: InkResponse(
                                onTap: () {
                                  switch (nowState) {
                                    case ActivityActive s:
                                      if (s.selected == s.active.activity) {
                                        context.read<NowBloc>().add(
                                            s.active.isRunning
                                                ? const ActivityStopped()
                                                : const ActivityResumed());
                                      }
                                    default:
                                      context.read<NowBloc>().add(
                                          ActivityStarted(nowState.selected));
                                      break;
                                  }
                                },
                                child: CircularProgressIndicator(
                                    value: nowState.progress,
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ));
  }
}
