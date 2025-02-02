part of 'priorities.dart';

final class PrioritiesState extends Equatable {
  PrioritiesState({
    required this.week,
    this.rootPriorities = const [],
    this.filter,
  })  : priorities = _mapPriorities(rootPriorities),
        balances = null;

  PrioritiesState._({
    required this.week,
    this.rootPriorities = const [],
    this.balances,
    this.filter,
  }) : priorities = _mapPriorities(rootPriorities);

  static Map<PriorityId, Priority> _mapPriorities(
      List<Priority> rootPriorities) {
    final priorities = <PriorityId, Priority>{};
    for (final priority in rootPriorities) {
      priorities[priority.id] = priority;
      for (final child in priority.children) {
        priorities[child.id] = child;
      }
    }
    return priorities;
  }

  final Priority? filter;
  final List<Priority> rootPriorities;
  final Map<PriorityId, Priority> priorities;
  List<Priority> get children => filter?.children ?? rootPriorities;
  List<Priority> get activeChildren => priorities.values
      .where((priority) =>
          (filter == null || filter!.isParent(priority)) &&
          (balances?[priority.id]?[BalanceType.todo]?.count ?? 0) > 0)
      .toList();
  List<Priority?> get recent =>
      List<Priority?>.of([null]) + priorities.values.toList();

  final Week week;
  final BalanceByPriorityType? balances;

  PrioritiesState copyWith({
    List<Priority>? priorities,
    Week? week,
    Value<BalanceByPriorityType?> balances = const Value.absent(),
    Priority? filter,
  }) {
    return PrioritiesState._(
      balances: balances.or(this.balances),
      rootPriorities: priorities ?? rootPriorities,
      week: week ?? this.week,
      filter: filter ?? this.filter,
    );
  }

  @override
  List<Object?> get props => [
        rootPriorities,
        week,
        balances,
      ];
}
