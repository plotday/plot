part of 'priorities.dart';

class PrioritiesState extends Equatable {
  const PrioritiesState({this.priorities = const [], this.root});

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

