import 'dart:math';

import 'package:plot/util/time.dart';
import 'model.dart';
import 'context.dart';

class Priority extends Model {
  static final Store<Week, Store<int, Priority>> _store =
      Store<Week, Store<int, Priority>>();

  static String _between(String? str1, String? str2) {
    if (str1 == null) {
      if (str2 == null) return "O";
      str1 = String.fromCharCode(max(32, str2.codeUnitAt(0) - 1));
    } else {
      str2 ??= String.fromCharCode(min(126, str1.codeUnitAt(0) + 1));
    }

    String newStr = "";
    for (int i = 0; true; i++) {
      final c1 = i < str1.length ? str1.codeUnitAt(i) : 32;
      final c2 = i < str2.length ? str2.codeUnitAt(i) : 126;
      final cn = ((c1 + c2) / 2).floor();

      if (c1 == cn || c2 == cn) {
        newStr += str1[i];
        continue;
      }

      newStr += String.fromCharCode(cn);
      break;
    }
    return newStr;
  }

  static Future<Priority> get(Week week, int contextId) async {
    final models = await list(week);
    return models[contextId];
  }

  static Future<List<Priority>> list(Week week) async {
    List<Priority> models;
    if (_store.has(week)) {
      models = _store.get(week).list();
    } else {
      final rows = await base
          .rpc<List<Map<String, dynamic>>>('priorities_for_week', params: {
        'user_id': base.auth.currentUser!.id,
        'week': week.toString(),
      });
      models = rows.map((json) => Priority.fromJson(week, json)).toList();
      final innerStore = Store<int, Priority>(
          values: Map.fromEntries(
        models.map((model) => MapEntry(model._contextId ?? 0, model)),
      ));
      _store.put(
        week,
        innerStore,
      );
    }
    final unbudgeted = Context.store
        .list()
        .where((context) =>
            !models.any((priority) => priority.context?.id == context.id))
        .map((context) {
      return Priority._(
        context.id!,
        week,
        budget: Duration.zero,
        scheduled: Duration.zero, // TODO
        order: 'Z${context.id.toString().padLeft(4, '0')}', // TODO
      );
    }).toList();

    final sortedBudgets = (models + unbudgeted)
      ..sort((a, b) => a._order.compareTo(b._order));

    _store
        .get(week)
        .set({for (var b in sortedBudgets) (b._contextId ?? 0): b}.entries);

    return _store.get(week).list();
  }

  // Order so this element is between after and before
  Priority(
    this._contextId,
    this.week, {
    required this.budget,
    required this.scheduled,
    required Priority? after,
    required Priority? before,
  }) : _order = _between(after?._order, before?._order);

  Priority.fromJson(this.week, Map<String, dynamic> json, {Duration? scheduled})
      : _contextId = json['context_id'] as int?,
        budget = Duration(minutes: json['budget'] as int? ?? 0),
        scheduled =
            scheduled ?? Duration(minutes: json['minutes'] as int? ?? 0),
        _order = json['order'] as String? ?? 'Z0000';

  const Priority._(
    this._contextId,
    this.week, {
    required this.budget,
    required this.scheduled,
    required String order,
  }) : _order = order;

  Priority copyWith({Duration? budget, Priority? after, Priority? before}) {
    String order = _order;
    if (after != null || before != null) {
      order = _between(after?._order, before?._order);
    }
    return Priority._(
      _contextId,
      week,
      budget: budget ?? this.budget,
      order: order,
      scheduled: scheduled,
    );
  }

  @override
  Future<Priority> save() async {
    if (!_store.has(week)) {
      await list(week);
    }
    _store.get(week).put(_contextId!, this);
    final row = await base
        .from('priority')
        .upsert(toJson(), onConflict: 'user_id,context_id,week')
        .select()
        .single();
    // Need to copy over scheduled, since we're only getting back the priority row,
    // not the view with scheduled.
    final model = Priority.fromJson(week, row, scheduled: scheduled);
    if (_store.has(week)) {
      _store.get(week).put(model._contextId!, model);
    } else {
      await list(week);
    }
    return model;
  }

  final int? _contextId;
  final Week week;
  final Duration budget;
  final Duration scheduled;
  final String _order;

  Context? get context =>
      _contextId != null ? Context.store.get(_contextId) : null;
  String get key => _contextId.toString();

  @override
  List<Object> get props => [_contextId ?? 0, budget, _order];

  @override
  Map<String, dynamic> toJson() => {
        'user_id': base.auth.currentUser!.id,
        'context_id': _contextId,
        'week': week.toString(),
        'budget': budget.inMinutes,
        'order': _order,
      };
}
