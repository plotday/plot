import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc.dart';
import 'time_block.dart';
import '../schedule/bloc.dart';
import '../clock.dart';

String formatDuration(Duration duration, {bool roundUp = false}) {
  final hours = duration.inHours;
  var minutes = duration.inMinutes.remainder(60);
  if (roundUp && duration.inSeconds.remainder(60) > 0) {
    minutes += 1;
  }
  return [hours > 0 ? hours.toString() : '', minutes.toString().padLeft(2, '0')]
      .join(':');
}

class PomodoroWidget extends StatelessWidget {
  const PomodoroWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
        stream: Clock().seconds,
        builder: (context, snapshot) =>
            BlocBuilder<ActivityBloc, ActivityState>(
              builder: (context, activityState) =>
                  BlocBuilder<ScheduleBloc, ScheduleState>(
                      builder: (context, scheduleState) {
                return Column(
                  children: [
                    Text(activityState.selected.name),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            children: [
                              Center(
                                child: Text(
                                  formatDuration(activityState.remaining,
                                      roundUp: true),
                                  style:
                                      Theme.of(context).textTheme.displaySmall,
                                ),
                              ),
                              Positioned.fill(
                                child: InkResponse(
                                    onTap: () {
                                      switch (activityState) {
                                        case ActivityActive s:
                                          if (s.selected == s.active.activity) {
                                            context.read<ActivityBloc>().add(
                                                s.active.isRunning
                                                    ? const ActivityStopped()
                                                    : const ActivityResumed());
                                          }
                                        default:
                                          context.read<ActivityBloc>().add(
                                              ActivityStarted(
                                                  activityState.selected));
                                          break;
                                      }
                                    },
                                    child: CircularProgressIndicator(
                                        value: activityState.progress,
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .outlineVariant)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ));
  }
}
