part of 'priority.dart';

sealed class PriorityState extends Equatable {
  const PriorityState(this.week);

  final Week week;

  @override
  List<Object?> get props => [week];
}

final class PriorityLoading extends PriorityState {
  const PriorityLoading(super.week);
}

final class PriorityLoaded extends PriorityState {
  const PriorityLoaded(super.week, this.priorities);

  final List<Priority> priorities;

  @override
  List<Object?> get props => super.props + [priorities];
}
