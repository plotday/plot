import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc.dart';
import '../activity.dart';
import '../../schedule/bloc.dart';
import '../../clock.dart';

String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  return [hours > 0 ? hours.toString() : '', minutes.toString().padLeft(2, '0')]
      .join(':');
}

class PomodoroTimer extends StatelessWidget {
  const PomodoroTimer({super.key, this.activity});

  final Activity? activity;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
        stream: Clock().seconds,
        builder: (context, snapshot) =>
            BlocBuilder<ActivityBloc, ActivityState>(
              builder: (context, activityState) =>
                  BlocBuilder<ScheduleBloc, ScheduleState>(
                      builder: (context, scheduleState) {
                double progress = 0;
                DateTime? end;
                if (scheduleState is ScheduleLoadedState) {
                  progress = scheduleState.currentProgress(activity) ?? 0;
                  end = scheduleState.endOf(activity);
                }
                if (progress == 0 && activityState is ActivityProgress) {
                  progress = activityState.progress(end: end);
                }
                return ConstrainedBox(
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
                                if (activityState is ActivityProgress)
                                  Text(
                                    formatDuration(activityState.duration),
                                    style: Theme.of(context)
                                        .textTheme
                                        .displaySmall,
                                  ),
                                if (activityState is! ActivityProgress)
                                  const Icon(
                                    Icons.play_arrow,
                                    size: 48.0,
                                    semanticLabel: 'Start',
                                  ),
                                if (activity != null)
                                  FittedBox(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16.0),
                                      child: Text(
                                        activity!.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .displaySmall,
                                      ),
                                    ),
                                  ),
                                if (scheduleState is ScheduleLoadedState &&
                                    scheduleState.endOf(activity) != null)
                                  Text(
                                    formatDuration(scheduleState
                                            .endOf(activity)!
                                            .difference(DateTime.now()) +
                                        const Duration(minutes: 1)),
                                    style: Theme.of(context)
                                        .textTheme
                                        .displaySmall,
                                  ),
                              ],
                            ),
                          ),
                          Positioned.fill(
                            child: InkResponse(
                              onTap: () {
                                switch (activityState) {
                                  case ActivityIdle _:
                                    if (activity != null) {
                                      context
                                          .read<ActivityBloc>()
                                          .add(ActivityStarted(activity!));
                                    }
                                    break;
                                  case ActivityProgressActive _:
                                    context
                                        .read<ActivityBloc>()
                                        .add(const ActivityPaused());
                                    break;
                                  case ActivityProgressPaused _:
                                    context
                                        .read<ActivityBloc>()
                                        .add(const ActivityResumed());
                                    break;
                                  default:
                                    break;
                                }
                              },
                              child: CircularProgressIndicator(
                                  value: progress,
                                  backgroundColor: Theme.of(context)
                                      .progressIndicatorTheme
                                      .circularTrackColor),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ));
  }
}
