part of 'bloc.dart';

sealed class PrioritiesState extends Equatable {
  const PrioritiesState(this.week);

  final Interval week;

  @override
  List<Object?> get props => [week];
}

final class PrioritiesLoading extends PrioritiesState {
  const PrioritiesLoading(super.week);
}

final class PrioritiesLoaded extends PrioritiesState {
  const PrioritiesLoaded(super.week, this.priorities);

  final List<Budget> priorities;

  @override
  List<Object?> get props => super.props + [priorities];
}
