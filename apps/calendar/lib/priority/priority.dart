import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import 'activity.dart';

final supabase = Supabase.instance.client;

class Priority extends Equatable {
  static final Map<DateTimeRange, Map<int?, Priority>> _cache = {};

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

  static Future<Priority> get(DateTimeRange week, int activityId) async {
    final budgets = await list(week);
    return budgets[activityId];
  }

  static Future<List<Priority>> list(DateTimeRange week) async {
    if (!_cache.containsKey(week)) {
      final results = await supabase.rpc('priorities_for_week', params: {
        'user_id': supabase.auth.currentUser!.id,
        'week': week.toString(),
      });
      final budgets = results.map<MapEntry<int?, Priority>>((json) {
        final budget = Priority.fromJson(week, json);
        return MapEntry(budget._activityId, budget);
      });
      _cache[week] = Map.fromEntries(budgets);
    }
    final budgets = _cache[week]?.values.toList() ?? [];
    final unbudgeted = Activity.list()
        .asMap()
        .entries
        .where((entry) =>
            !budgets.any((budget) => budget.activity?.id == entry.value.id))
        .map((entry) {
      return Priority._(
        entry.value.id!,
        week,
        budget: Duration.zero,
        planned: Duration.zero, // TODO
        order: 'Z${entry.key.toString().padLeft(4, '0')}',
      );
    }).toList();

    final sortedBudgets = (budgets + unbudgeted)
      ..sort((a, b) => a._order.compareTo(b._order));

    _cache[week] = {for (var b in sortedBudgets) (b._activityId ?? 0): b};

    return _cache[week]!.values.toList();
  }

  // Order so this element is between after and before
  Priority(
    this._activityId,
    this.week, {
    required this.budget,
    required this.planned,
    required Priority? after,
    required Priority? before,
  }) : _order = _between(after?._order, before?._order);

  Priority.fromJson(
    this.week,
    Map<String, dynamic> json,
  )   : _activityId = json['activity_id'] as int?,
        budget = Duration(minutes: json['budget'] as int? ?? 0),
        planned = Duration(minutes: json['minutes'] as int? ?? 0),
        _order = json['order'] as String? ?? 'Z0000';

  const Priority._(
    this._activityId,
    this.week, {
    required this.budget,
    required this.planned,
    required order,
  }) : _order = order;

  Priority copyWith({Duration? budget, Priority? after, Priority? before}) {
    String order = _order;
    if (after != null || before != null) {
      order = _between(after?._order, before?._order);
    }
    return Priority._(_activityId, week,
        budget: budget ?? this.budget, order: order, planned: planned);
  }

  Future<Priority> save() async {
    _cache[week] ??= {};
    _cache[week]![_activityId] = this;

    final result = await supabase
        .from('priority')
        .upsert(toJson(), onConflict: 'user_id,activity_id,week')
        .select()
        .single();
    return Priority.fromJson(week, result);
  }

  final int? _activityId;
  final DateTimeRange week;
  final Duration budget;
  final Duration planned;
  Activity? get activity =>
      _activityId != null ? Activity.get(_activityId) : null;
  get key => _activityId.toString();

  final String _order;

  @override
  List<Object> get props => [_activityId ?? 0, budget, _order];

  Map<String, dynamic> toJson() => {
        'user_id': supabase.auth.currentUser!.id,
        'activity_id': _activityId,
        'week': week.toString(),
        'budget': budget.inMinutes,
        'order': _order,
      };
}
