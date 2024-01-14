part of 'bloc.dart';

sealed class NowState extends Equatable {
  const NowState(this.selected);

  final Activity selected;

  @override
  List<Object?> get props => [selected];

  NowState copyWith({Activity? selected});

  get remaining => selected.pomodoro;

  get progress => 0.0;
}

final class ActivityIdle extends NowState {
  const ActivityIdle(super.selected);

  @override
  ActivityIdle copyWith({Activity? selected}) {
    return ActivityIdle(selected ?? this.selected);
  }
}

class ActivityActive extends NowState {
  const ActivityActive(this.active, {required Activity selected})
      : super(selected);

  final TimeBlock active;

  @override
  List<Object?> get props => super.props + [active];

  @override
  ActivityActive copyWith({Activity? selected, TimeBlock? active}) {
    return ActivityActive(active ?? this.active,
        selected: selected ?? this.selected);
  }

  @override
  get remaining => active.remaining;

  @override
  get progress => active.progress;
}
