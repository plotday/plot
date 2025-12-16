import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'local_preferences_state.dart';

/// Bloc for managing local app preferences that are not synced to the server
class LocalPreferencesBloc extends Cubit<LocalPreferencesState> {
  LocalPreferencesBloc()
      : super(const LocalPreferencesState(mentionMruIds: [])) {
    _loadFromPreferences();
  }

  static const String _kMentionMruKey = 'mention_mru_ids';
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
  /// Items not in the MRU list will be placed after MRU items in their original order
  List<T> sortByMentionMru<T>(List<T> items, String Function(T) getId) {
    if (state.mentionMruIds.isEmpty) {
      return items;
    }

    final mruOrder = <String, int>{};
    for (var i = 0; i < state.mentionMruIds.length; i++) {
      mruOrder[state.mentionMruIds[i]] = i;
    }

    return items.toList()
      ..sort((a, b) {
        final aIndex = mruOrder[getId(a)] ?? 999999;
        final bIndex = mruOrder[getId(b)] ?? 999999;
        return aIndex.compareTo(bIndex);
      });
  }

  /// Load state from shared preferences
  Future<void> _loadFromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final idsString = prefs.getString(_kMentionMruKey);
    if (idsString != null && idsString.isNotEmpty) {
      final ids = idsString.split(',');
      emit(state.copyWith(mentionMruIds: ids));
    }
  }

  /// Persist state to shared preferences
  Future<void> _persistState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMentionMruKey, state.mentionMruIds.join(','));
  }
}
