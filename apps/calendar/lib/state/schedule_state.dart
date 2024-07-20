part of 'schedule.dart';

sealed class ScheduleState extends Equatable {
  ScheduleState({
    Date? day,
  })  : day = day ?? Date.today(),
        _sequence = 1;

  ScheduleState.copy(ScheduleState copy, {Date? day})
      : day = day ?? copy.day,
        _sequence = copy._sequence + 1;

  ScheduleState copyWith({
    Date? day,
    Optional<ScheduledEvent> selected = const Optional.absent(),
    String? error,
    bool loading = false,
  }) {
    if (selected.isPresent) {
      if (selected.isNotNull) {
        return SelectedEventState.copy(
          this,
          selected: selected.value!,
        );
      } else {
        return ScheduleListState.copy(
          this,
          day: day ?? this.day,
        );
      }
    }
    if (error != null) {
      return SelectedEventErrorState.copy(
        this,
        error: error,
      );
    }
    if (loading) {
      return SelectedEventLoadingState.copy(this);
    }
    switch (this) {
      case SelectedEventState state:
        return SelectedEventState.copy(
          this,
          selected: state.selected,
        );
      case SelectedEventErrorState state:
        return SelectedEventErrorState.copy(
          this,
          error: state.error,
        );
      case SelectedEventLoadingState _:
        return SelectedEventLoadingState.copy(this);
      case ScheduleListState state:
        return ScheduleListState.copy(
          this,
          day: day ?? state.day,
        );
    }
  }

  final Date day;
  final int _sequence;

  Week get week => Week(day);

  @override
  List<Object?> get props => [day, _sequence];
}

final class ScheduleListState extends ScheduleState {
  ScheduleListState({
    super.day,
  });

  ScheduleListState.copy(
    ScheduleState copy, {
    Date? day,
  }) : super.copy(copy, day: day);
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
  SelectedEventLoadingState();

  SelectedEventLoadingState.copy(
    ScheduleState copy,
  ) : super.copy(copy);
}
