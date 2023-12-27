part of 'bloc.dart';

sealed class ScheduleState extends Equatable {
  const ScheduleState();

  @override
  List<Object> get props => [];
}

final class ScheduleLoadingState extends ScheduleState {
  const ScheduleLoadingState();
}

final class ScheduleLoadedState extends ScheduleState {
  const ScheduleLoadedState(this.current, this.next);

  final List<ScheduledEvent> current;
  final List<ScheduledEvent> next;

  ScheduledEvent? currentOf(Activity? activity) {
    final active = current.where((ScheduledEvent event) {
      return activity == null || event.activity == activity;
    });
    if (active.isNotEmpty) {
      return active.first;
    }
    return null;
  }

  DateTime? endOf(Activity? activity) {
    final active = currentOf(activity);
    if (active != null) {
      return active.at.end;
    }
    if (next.isNotEmpty) {
      return next.first.at.start;
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

  @override
  List<Object> get props => [current, next];
}
