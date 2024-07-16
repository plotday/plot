part of 'schedule.dart';

final class ScheduleState extends Equatable {
  ScheduleState({
    Date? day,
  })  : day = day ?? Date.today(),
        _sequence = 1;

  ScheduleState.copy(ScheduleState copy, {Date? day})
      : day = day ?? copy.day,
        _sequence = copy._sequence + 1;

  ScheduleState copyWith({
    Date? day,
    ScheduledEvent? selected,
    String? error,
    bool loading = false,
  }) {
    final state = ScheduleState.copy(
      this,
      day: day ?? this.day,
    );
    if (error != null) {
      return SelectedEventErrorState.copy(
        state,
        error: error,
      );
    }
    if (loading) {
      return SelectedEventLoadingState.copy(state);
    }
    if (selected != null) {
      return SelectedEventState.copy(
        state,
        selected: selected,
      );
    }
    return state;
  }

  final Date day;
  final int _sequence;

  Week get week => Week(day);

  @override
  List<Object?> get props => [day, _sequence];
}

final class SelectedEventState extends ScheduleState {
  SelectedEventState.copy(
    ScheduleState copy, {
    required this.selected,
  }) : super.copy(copy);

  final ScheduledEvent selected;

  @override
  List<Object?> get props => super.props + [selected];
}

final class SelectedEventErrorState extends ScheduleState {
  SelectedEventErrorState.copy(
    ScheduleState copy, {
    required this.error,
  }) : super.copy(copy);

  final String error;

  @override
  List<Object?> get props => super.props + [error];
}

final class SelectedEventLoadingState extends ScheduleState {
  SelectedEventLoadingState.copy(
    ScheduleState copy,
  ) : super.copy(copy);
}
