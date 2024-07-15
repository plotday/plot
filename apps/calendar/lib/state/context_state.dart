part of 'context.dart';

sealed class ContextState extends Equatable {
  static List<Context> _filterChildren(List<Context> all, Context? current) {
    final children = all.where((context) => context.parent == current).toList();
    children.sort();
    return children;
  }

  ContextState({
    required List<Context> contexts,
    this.current,
  })  : all = contexts,
        children = _filterChildren(contexts, current);

  final List<Context> all;
  final Context? current;
  final List<Context> children;

  ContextState copyWith({
    List<Context>? contexts,
    List<Budget>? budgets = const [],
    Context? current,
    Week? week,
  });

  @override
  List<Object?> get props => [all, current];
}

final class BudgetsLoadingState extends ContextState {
  BudgetsLoadingState({required super.contexts, Week? week, super.current})
      : week = week ?? Week.current();

  final Week week;

  @override
  ContextState copyWith({
    List<Context>? contexts,
    List<Budget>? budgets = const [],
    Context? current = Context.unchanged,
    Week? week,
  }) {
    if (budgets?.isNotEmpty == true) {
      return BudgetsLoadedState(
        contexts: contexts ?? all,
        budgets: budgets!,
        current: current ?? this.current,
        week: week ?? this.week,
      );
    }
    return BudgetsLoadingState(
      contexts: contexts ?? all,
      current: current == Context.unchanged ? this.current : current,
      week: week ?? this.week,
    );
  }

  @override
  List<Object?> get props => super.props + [week];
}

final class BudgetsLoadedState extends ContextState {
  BudgetsLoadedState({
    required List<Budget> budgets,
    required super.contexts,
    super.current,
    required this.week,
  }) : _budgets =
            Map.fromEntries(budgets.map((b) => MapEntry(b.context!.id!, b)));

  final Week week;
  final Map<int, Budget> _budgets;

  Budget? budgetFor(Context context) => _budgets[context.id];

  @override
  ContextState copyWith({
    List<Context>? contexts,
    List<Budget>? budgets = const [],
    Budget? budget,
    Context? current,
    Week? week,
  }) {
    if (budgets?.isEmpty == true) {
      budgets = _budgets.values.toList();
      if (budget != null) {
        budgets = budgets.replace(budget, (b1, b2) => b1.id == b2.id);
      }
    }
    if (budgets == null || week != this.week) {
      return BudgetsLoadingState(
        contexts: contexts ?? all,
        current: current ?? this.current,
        week: week ?? this.week,
      );
    }
    return BudgetsLoadedState(
      contexts: all,
      budgets: budgets,
      current: current ?? this.current,
      week: week ?? this.week,
    );
  }

  @override
  List<Object?> get props => super.props + [week];
}
