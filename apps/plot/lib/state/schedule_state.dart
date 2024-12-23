part of 'schedule.dart';

final class ScheduleState extends Equatable {
  ScheduleState({
    Date? day,
    this.schedule = const {},
    this.selected,
  })  : day = day ?? Date.today(),
        anchor = Date.today();

  ScheduleState.copy(
    ScheduleState copy, {
    Date? day,
    Map<Date, ScheduledDay>? schedule,
    Event? selected,
  })  : day = day ?? copy.day,
        anchor = copy.anchor,
        schedule = schedule ?? copy.schedule,
        selected = selected ?? copy.selected;

  ScheduleState copyWith({
    Date? day,
    Map<Date, ScheduledDay>? schedule,
    Value<Event?> selected = const Value.absent(),
    bool loading = false,
  }) {
    return ScheduleState.copy(
      this,
      day: day ?? this.day,
      selected: selected.or(this.selected),
      schedule: schedule ?? this.schedule,
    );
  }

  final Date day; // selected day
  final Date anchor; // used to calculate relative offset of watch range
  final Map<Date, ScheduledDay> schedule;
  final Event? selected;

  Week get week => Week(day);
  DateRange get range => DateRangeCustom(
        schedule.keys.firstOrNull ?? day,
        schedule.keys.lastOrNull?.next() ?? day,
      );

  @override
  List<Object?> get props => [day, schedule, selected];
}
