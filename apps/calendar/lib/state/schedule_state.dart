part of 'schedule.dart';

sealed class ScheduleState extends Equatable {
  ScheduleState({
    Date? day,
    this.schedule = const {},
  })  : day = day ?? Date.today(),
        anchor = Date.today();

  ScheduleState.copy(ScheduleState copy,
      {Date? day, Map<Date, ScheduledDay>? schedule})
      : day = day ?? copy.day,
        anchor = copy.anchor,
        schedule = schedule ?? copy.schedule;

  ScheduleState copyWith({
    Date? day,
    Map<Date, ScheduledDay>? schedule,
    Optional<Event> selected = const Optional.absent(),
    String? error,
    bool loading = false,
  }) {
    if (selected.isPresent) {
      if (selected.isNotNull) {
        return SelectedEventState.copy(
          this,
          selected: selected.value!,
          schedule: schedule ?? this.schedule,
        );
      } else {
        return ScheduleListState.copy(
          this,
          day: day ?? this.day,
          schedule: schedule ?? this.schedule,
        );
      }
    }
    if (error != null) {
      return SelectedEventErrorState.copy(
        this,
        error: error,
        schedule: schedule ?? this.schedule,
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
          schedule: schedule ?? state.schedule,
        );
      case SelectedEventErrorState state:
        return SelectedEventErrorState.copy(
          this,
          error: state.error,
          schedule: schedule ?? state.schedule,
        );
      case SelectedEventLoadingState _:
        return SelectedEventLoadingState.copy(
          this,
          schedule: schedule ?? this.schedule,
        );
      case ScheduleListState state:
        return ScheduleListState.copy(
          this,
          day: day ?? state.day,
          schedule: schedule ?? state.schedule,
        );
    }
  }

  final Date day; // selected day
  final Date anchor; // used to calculate relative offset of watch range
  Week get week => Week(day);

  final Map<Date, ScheduledDay> schedule;
  DateRange get range => DateRangeCustom(
        schedule.keys.firstOrNull ?? day,
        schedule.keys.lastOrNull?.next() ?? day,
      );

  @override
  List<Object?> get props => [day, schedule];
}

final class ScheduleListState extends ScheduleState {
  ScheduleListState({
    super.day,
    super.schedule,
  });

  ScheduleListState.copy(
    super.copy, {
    super.day,
    super.schedule,
  }) : super.copy();
}

final class SelectedEventState extends ScheduleState {
  SelectedEventState.copy(
    super.copy, {
    required this.selected,
    super.schedule,
  }) : super.copy();

  final Event selected;

  @override
  List<Object?> get props => super.props + [selected];
}

final class SelectedEventErrorState extends ScheduleState {
  SelectedEventErrorState.copy(
    super.copy, {
    required this.error,
    super.schedule,
  }) : super.copy();

  final String error;

  @override
  List<Object?> get props => super.props + [error];
}

final class SelectedEventLoadingState extends ScheduleState {
  SelectedEventLoadingState();

  SelectedEventLoadingState.copy(
    super.copy, {
    super.schedule,
  }) : super.copy();
}
