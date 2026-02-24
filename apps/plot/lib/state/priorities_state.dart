part of 'priorities.dart';

@immutable
class PrioritiesState extends Equatable {
  PrioritiesState({
    List<Priority> priorities = const [],
    this.root,
    this.archivedFilter = false,
    this.search = '',
  }) : priorities = priorities.isNotEmpty
          ? List.unmodifiable(priorities)
          : priorities;

  final Priority? root;
  final List<Priority> priorities;

  /// Archived filter state: false = active only, null = show all
  final bool? archivedFilter;

  final String search;

  PrioritiesState copyWith({
    List<Priority>? priorities,
    Priority? root,
    bool? archivedFilter,
    String? search,
  }) {
    return PrioritiesState(
      priorities: priorities ?? this.priorities,
      root: root ?? this.root,
      archivedFilter: archivedFilter ?? this.archivedFilter,
      search: search ?? this.search,
    );
  }

  @override
  List<Object?> get props => [priorities, root, archivedFilter, search];
}
