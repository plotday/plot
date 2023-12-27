part of 'bloc.dart';

sealed class ActivityState extends Equatable {
  const ActivityState();

  @override
  List<Object> get props => [];
}

final class ActivityIdle extends ActivityState {
  const ActivityIdle();
}

abstract class ActivityProgress extends ActivityState {
  const ActivityProgress(this.current, this.started);

  final Activity current;
  final DateTime started;

  Duration get duration;

  double progress(Duration duration) {
    return this.duration.inSeconds / duration.inSeconds;
  }

  @override
  List<Object> get props => super.props + [current, started];
}

final class ActivityProgressActive extends ActivityProgress {
  ActivityProgressActive(super.current, super.started, this._duration);

  final Duration _duration;
  final DateTime _restarted = DateTime.now();

  @override
  get duration => _duration + DateTime.now().difference(_restarted);

  @override
  List<Object> get props => super.props + [_duration, _restarted];
}

final class ActivityProgressPaused extends ActivityProgress {
  const ActivityProgressPaused(super.current, super.started, this.duration);

  @override
  final Duration duration;

  @override
  List<Object> get props => super.props + [duration];
}
