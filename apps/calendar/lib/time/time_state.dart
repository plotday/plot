part of 'time_bloc.dart';

sealed class TimeState extends Equatable {
  const TimeState();

  @override
  List<Object> get props => [];
}

final class TimeIdle extends TimeState {
  const TimeIdle();
}

class TimeProgress extends TimeState {
  const TimeProgress(this.duration);

  final int duration;

  @override
  List<Object> get props => [duration];
}

final class TimeProgressActive extends TimeProgress {
  const TimeProgressActive(super.duration);
}

final class TimeProgressPaused extends TimeProgress {
  const TimeProgressPaused(super.duration);
}
