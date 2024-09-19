import 'package:plot/util/time.dart';
import 'model.dart';
import 'context.dart';

typedef BudgetID = int;

class Budget extends IdModel<BudgetID> {
  static final Store<Week, Store<ContextID?, Budget>> _store =
      Store<Week, Store<ContextID?, Budget>>();

  static Future<Budget> get(Week week, ContextID contextId) async {
    await list(week);
    return _store.get(week).get(contextId);
  }

  static Future<List<Budget>> list(Week week) async {
    List<Budget> models;
    if (_store.has(week)) {
      models = _store.get(week).list();
    } else {
      final rows = await base.rpc<List<Map<String, dynamic>>>(
        'balance',
        params: {
          'user_id': base.auth.currentUser!.id,
          'week': week.toString(),
        },
      );
      models = rows.map((json) => Budget.fromJson(week, json)).toList();
      final innerStore = Store<ContextID?, Budget>(
          values: Map.fromEntries(
        models.map((model) => MapEntry(model._contextId, model)),
      ));
      _store.put(
        week,
        innerStore,
      );
    }
    final unbudgeted = Context.store
        .list()
        .where((context) =>
            !models.any((budget) => budget.context?.id == context.id))
        .map((context) {
      return Budget(
        context.id,
        week,
        budget: Duration.zero,
        scheduled: Duration.zero, // TODO
      );
    }).toList();

    final budgets = (models + unbudgeted);
    _store.get(week).set({for (var b in budgets) (b._contextId): b}.entries);

    return _store.get(week).list();
  }

  // Order so this element is between after and before
  const Budget(
    this._contextId,
    this.week, {
    required this.budget,
    required this.scheduled,
  });

  Budget.fromJson(this.week, Map<String, dynamic> json, {Duration? scheduled})
      : _contextId = json['context_id'] as ContextID?,
        budget = Duration(minutes: json['budget'] as int? ?? 0),
        scheduled =
            scheduled ?? Duration(minutes: json['minutes'] as int? ?? 0);

  Budget copyWith({Duration? budget}) {
    return Budget(
      _contextId,
      week,
      budget: budget ?? this.budget,
      scheduled: scheduled,
    );
  }

  @override
  Future<Budget> save() async {
    if (!_store.has(week)) {
      await list(week);
    }
    _store.get(week).put(_contextId!, this);
    final row = await base
        .from('budget')
        .upsert(toJson(), onConflict: 'user_id,context_id,week')
        .select()
        .single();
    // Need to copy over scheduled, since we're only getting back the budget row,
    // not the view with scheduled.
    final model = Budget.fromJson(week, row, scheduled: scheduled);
    if (_store.has(week)) {
      _store.get(week).put(model._contextId!, model);
    } else {
      await list(week);
    }
    return model;
  }

  final ContextID? _contextId;
  final Week week;
  final Duration budget;
  final Duration scheduled;

  Context? get context =>
      _contextId != null ? Context.store.get(_contextId) : null;
  String get key => _contextId?.toString() ?? 'null';

  @override
  List<Object?> get props => super.props + [_contextId, budget];

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'context_id': _contextId,
        'week': week.toString(),
        'budget': budget.inMinutes,
      };
}
