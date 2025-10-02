part of 'priorities.dart';

@immutable
class PrioritiesState extends Equatable {
  PrioritiesState({List<Priority> priorities = const [], this.root})
    : priorities = priorities.isNotEmpty
          ? List.unmodifiable(priorities)
          : priorities;

  final Priority? root;
  final List<Priority> priorities;

  PrioritiesState copyWith({List<Priority>? priorities, Priority? root}) {
    return PrioritiesState(
      priorities: priorities ?? this.priorities,
      root: root ?? this.root,
    );
  }

  @override
  List<Object?> get props => [priorities];
}
