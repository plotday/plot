import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import 'activity.dart';

final supabase = Supabase.instance.client;

class Budget extends Equatable {
  static final Map<DateTimeRange, Map<int, Budget>> _cache = {};

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

  static Future<Budget> get(DateTimeRange week, int activityId) async {
    final budgets = await list(week);
    return budgets[activityId];
  }

  static Future<List<Budget>> list(DateTimeRange week) async {
    if (!_cache.containsKey(week)) {
      final results = await supabase.rpc('budget_week', params: {
        'user_id': supabase.auth.currentUser!.id,
        'week': week.toString()
      });
      final budgets = results.map<MapEntry<int, Budget>>((json) {
        final budget = Budget.fromJson(week, json);
        return MapEntry(budget._activityId, budget);
      });
      _cache[week] = Map.fromEntries(budgets);
    }
    final budgets = _cache[week]?.values.toList() ?? [];
    final unbudgeted = Activity.list()
        .asMap()
        .entries
        .where((entry) =>
            !budgets.any((budget) => budget.activity.id == entry.value.id))
        .map((entry) {
      return Budget._(entry.value.id!, week, Duration.zero,
          'Z${entry.key.toString().padLeft(4, '0')}');
    }).toList();
    final sortedBudgets = (budgets + unbudgeted)
      ..sort((a, b) => a._order.compareTo(b._order));
    _cache[week] = {for (var b in sortedBudgets) b._activityId: b};
    return _cache[week]!.values.toList();
  }

  // Order so this element is between after and before
  Budget(
    this._activityId,
    this.week,
    this.duration, {
    required Budget? after,
    required Budget? before,
  }) : _order = _between(after?._order, before?._order);

  Budget.fromJson(
    this.week,
    Map<String, dynamic> json,
  )   : _activityId = json['activity_id'] as int,
        duration = Duration(minutes: json['budget'] as int),
        _order = json['order'] as String;

  const Budget._(this._activityId, this.week, this.duration, this._order);

  Budget copyWith({Duration? duration, Budget? after, Budget? before}) {
    String order = _order;
    if (after != null || before != null) {
      order = _between(after?._order, before?._order);
    }
    return Budget._(_activityId, week, duration ?? this.duration, order);
  }

  Future<Budget> save() async {
    // Update cache
    _cache[week] ??= {};
    _cache[week]![_activityId] = this;

    // TODO run these queries in parallel
    await supabase
        .from('budget')
        .upsert(toJson(), onConflict: 'user_id,activity_id,week');
    final result = await supabase
        .from('budget')
        .upsert(toJson(), onConflict: 'user_id,activity_id,week')
        .select()
        .single();
    return Budget.fromJson(week, result);
  }

  final int _activityId;
  final DateTimeRange week;
  final Duration duration;
  get activity => Activity.get(_activityId);
  get key => _activityId.toString();

  final String _order;

  @override
  List<Object> get props => [_activityId, duration, _order];

  Map<String, dynamic> toJson() => {
        'user_id': supabase.auth.currentUser!.id,
        'activity_id': _activityId,
        'week': week.toString(),
        'budget': duration.inMinutes,
        'order': _order,
      };
}
