part of 'bloc.dart';

sealed class ActivityState extends Equatable {
  const ActivityState({this.selected});

  final Activity? selected;

  @override
  List<Object?> get props => [selected];

  ActivityState copyWith({Activity? selected});
}

final class ActivityIdle extends ActivityState {
  const ActivityIdle({super.selected});

  @override
  ActivityIdle copyWith({Activity? selected}) {
    return ActivityIdle(selected: selected ?? this.selected);
  }
}

abstract class ActivityProgress extends ActivityState {
  const ActivityProgress(this.active, {super.selected, required this.at});

  final Activity active;
  final Interval at;

  Duration get elapsed;

  double progress(Duration duration) {
    return elapsed.inSeconds / duration.inSeconds;
  }

  @override
  List<Object?> get props => super.props + [active, at];
}

final class ActivityProgressActive extends ActivityProgress {
  ActivityProgressActive(
    super.active,
    this._elapsed, {
    super.selected,
    required super.at,
  });

  final Duration _elapsed;
  final DateTime _restarted = DateTime.now();

  @override
  get elapsed => _elapsed + DateTime.now().difference(_restarted);

  @override
  List<Object?> get props => super.props + [_elapsed, _restarted];

  @override
  ActivityProgress copyWith({Activity? selected}) {
    return ActivityProgressActive(active, _elapsed,
        selected: selected ?? this.selected, at: at);
  }
}

final class ActivityProgressPaused extends ActivityProgress {
  const ActivityProgressPaused(
    super.active,
    this.elapsed, {
    super.selected,
    required super.at,
  });

  @override
  final Duration elapsed;

  @override
  List<Object?> get props => super.props + [elapsed];

  @override
  ActivityProgress copyWith({Activity? selected}) {
    return ActivityProgressActive(active, elapsed,
        selected: selected ?? this.selected, at: at);
  }
}
