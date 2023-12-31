part of 'bloc.dart';

sealed class ActivityState extends Equatable {
  const ActivityState({this.selected});

  final Activity? selected;

  @override
  List<Object> get props => [];
}

final class ActivityIdle extends ActivityState {
  const ActivityIdle({super.selected});
}

abstract class ActivityProgress extends ActivityState {
  const ActivityProgress(this.active, {super.selected, required this.started});

  final Activity active;
  final DateTime started;

  Duration get duration;

  double progress(Duration duration) {
    return this.duration.inSeconds / duration.inSeconds;
  }

  @override
  List<Object> get props => super.props + [active, started];
}

final class ActivityProgressActive extends ActivityProgress {
  ActivityProgressActive(
    super.active,
    this._duration, {
    super.selected,
    required super.started,
  });

  final Duration _duration;
  final DateTime _restarted = DateTime.now();

  @override
  get duration => _duration + DateTime.now().difference(_restarted);

  @override
  List<Object> get props => super.props + [_duration, _restarted];
}

final class ActivityProgressPaused extends ActivityProgress {
  const ActivityProgressPaused(
    super.active,
    this.duration, {
    super.selected,
    required super.started,
  });

  @override
  final Duration duration;

  @override
  List<Object> get props => super.props + [duration];
}
