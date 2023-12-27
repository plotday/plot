import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc.dart';
import '../activity.dart';
import '../activity_preferences.dart';
import '../../schedule/bloc.dart';
import '../../clock.dart';

String formatDuration(Duration duration, {bool roundUp = false}) {
  final hours = duration.inHours;
  var minutes = duration.inMinutes.remainder(60);
  if (roundUp && duration.inSeconds.remainder(60) > 0) {
    minutes += 1;
  }
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
                final Duration available = ActivityPreferences.sessionDuration(
                    end != null ? DateTime.now().difference(end) : null);
                if (progress == 0 && activityState is ActivityProgress) {
                  progress = activityState.progress(available);
                }
                var remaining = available;
                if (activityState is ActivityProgress) {
                  remaining -= activityState.duration;
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
                                Text(
                                  formatDuration(remaining, roundUp: true),
                                  style:
                                      Theme.of(context).textTheme.displaySmall,
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
