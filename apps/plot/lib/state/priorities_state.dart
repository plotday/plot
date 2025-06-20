part of 'priorities.dart';

class PrioritiesState extends Equatable {
  const PrioritiesState({
    this.priorities = const [],
  });

  final List<Priority> priorities;

  PrioritiesState copyWith({
    List<Priority>? priorities,
  }) {
    return PrioritiesState(
      priorities: priorities ?? this.priorities,
    );
  }

  @override
  List<Object?> get props => [priorities];
}