import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/util/profile_preferences.dart';

part 'local_preferences_state.dart';

/// Bloc for managing local app preferences that are not synced to the server
class LocalPreferencesBloc extends Cubit<LocalPreferencesState> {
  LocalPreferencesBloc()
      : super(const LocalPreferencesState(mentionMruIds: [])) {
    _loadFromPreferences();
  }

  static const String _kMentionMruKey = 'mention_mru_ids';
  static const String _kShowAllPrioritiesKey = 'show_all_priorities';
  static const int _maxMruItems = 50;

  /// Record usage of a mention, moving it to the front of the MRU list
  Future<void> recordMentionUsage(String priorityTwistId) async {
    final currentIds = List<String>.from(state.mentionMruIds);

    // Remove if exists (to move to front)
    currentIds.remove(priorityTwistId);

    // Add to front
    currentIds.insert(0, priorityTwistId);

    // Limit size
    if (currentIds.length > _maxMruItems) {
      currentIds.removeRange(_maxMruItems, currentIds.length);
    }

    emit(state.copyWith(mentionMruIds: currentIds));
    await _persistState();
  }

  /// Sort a list of items by mention MRU order
  /// Items not in the MRU list will be placed after MRU items in their original order.
  /// Low-priority items (e.g. contacts) sort after other non-MRU items.
  List<T> sortByMentionMru<T>(
    List<T> items,
    String Function(T) getId, {
    bool Function(T)? isLowPriority,
  }) {
    if (state.mentionMruIds.isEmpty && isLowPriority == null) {
      return items;
    }

    final mruOrder = <String, int>{};
    for (var i = 0; i < state.mentionMruIds.length; i++) {
      mruOrder[state.mentionMruIds[i]] = i;
    }

    return items.toList()
      ..sort((a, b) {
        final aInMru = mruOrder.containsKey(getId(a));
        final bInMru = mruOrder.containsKey(getId(b));
        final aIndex = aInMru
            ? mruOrder[getId(a)]!
            : (isLowPriority?.call(a) ?? false ? 999999 : 999998);
        final bIndex = bInMru
            ? mruOrder[getId(b)]!
            : (isLowPriority?.call(b) ?? false ? 999999 : 999998);
        return aIndex.compareTo(bIndex);
      });
  }

  /// Toggle showing all priorities (active + archived) vs active only
  Future<void> toggleShowAllPriorities() async {
    emit(state.copyWith(showAllPriorities: !state.showAllPriorities));
    await _persistState();
  }

  /// Load state from profile preferences
  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    final idsString = prefs.getString(_kMentionMruKey);
    final showAllPriorities = prefs.getBool(_kShowAllPrioritiesKey) ?? false;

    emit(state.copyWith(
      mentionMruIds: idsString != null && idsString.isNotEmpty
          ? idsString.split(',')
          : null,
      showAllPriorities: showAllPriorities,
    ));
  }

  /// Persist state to profile preferences
  Future<void> _persistState() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(_kMentionMruKey, state.mentionMruIds.join(','));
    await prefs.setBool(_kShowAllPrioritiesKey, state.showAllPriorities);
  }
}
