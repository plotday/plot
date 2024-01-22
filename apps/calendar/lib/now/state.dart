part of 'bloc.dart';

sealed class NowState extends Equatable {
  const NowState({this.selected, this.current, this.next});

  final Activity? selected;
  final ScheduledEvent? current;
  final ScheduledEvent? next;

  @override
  List<Object?> get props => [selected, current, next];

  NowState copyWith(
      {Activity? selected, ScheduledEvent? current, ScheduledEvent? next});

  get remaining => selected?.pomodoro ?? const Duration(minutes: 25);

  get progress => 0.0;

  ScheduledEvent? currentOf(Activity? activity) {
    return current?.activity == activity ? current : null;
  }

  DateTime? endOf(Activity? activity) {
    final active = currentOf(activity);
    if (active != null) {
      return active.at.end;
    }
    if (next != null) {
      return next!.at.start;
    }
    return null;
  }

  double? currentProgress(Activity? activity) {
    final active = currentOf(activity);
    if (active == null) return null;
    final total = active.at.end.difference(active.at.start).inSeconds;
    if (total == 0) return null;
    return DateTime.now().difference(active.at.start).inSeconds / total;
  }
}

final class ActivityIdle extends NowState {
  const ActivityIdle({super.selected, super.current, super.next});

  @override
  ActivityIdle copyWith(
      {Activity? selected, ScheduledEvent? current, ScheduledEvent? next}) {
    return ActivityIdle(
        selected: selected ?? this.selected,
        current: current ?? this.current,
        next: next ?? this.next);
  }
}

class ActivityActive extends NowState {
  const ActivityActive(this.active,
      {required Activity selected, super.current, super.next})
      : super(selected: selected);

  final TimeBlock active;

  @override
  List<Object?> get props => super.props + [active];

  @override
  ActivityActive copyWith(
      {TimeBlock? active,
      Activity? selected,
      ScheduledEvent? current,
      ScheduledEvent? next}) {
    return ActivityActive(
      active ?? this.active,
      selected:
          selected ?? this.selected ?? active?.activity ?? this.active.activity,
      current: current ?? this.current,
      next: next ?? this.next,
    );
  }

  @override
  get remaining => active.remaining;

  @override
  get progress => active.progress;
}
