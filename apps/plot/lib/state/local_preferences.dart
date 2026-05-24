import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart' show ThreadSubType;
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
  static const String _kSubTypeMruPrefix = 'thread_subtype_mru:';
  static const String _kConnectionMruKey = 'connection_mru';
  static const int _maxMruItems = 50;

  /// Record usage of a mention, moving it to the front of the MRU list
  Future<void> recordMentionUsage(String twistInstanceId) async {
    final currentIds = List<String>.from(state.mentionMruIds);

    // Remove if exists (to move to front)
    currentIds.remove(twistInstanceId);

    // Add to front
    currentIds.insert(0, twistInstanceId);

    // Limit size
    if (currentIds.length > _maxMruItems) {
      currentIds.removeRange(_maxMruItems, currentIds.length);
    }

    emit(state.copyWith(mentionMruIds: currentIds));
    await _persistState();
  }

  /// Record that the user just used [channelKey] (a `CreateTarget.key`) while
  /// in [priorityId]. Both this priority's timestamp and the global timestamp
  /// are bumped to now so rankings reflect the latest use.
  Future<void> recordConnectionUsage({
    required String channelKey,
    required String priorityId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = Map<String, ConnectionMruEntry>.from(state.connectionMru);
    final existing = next[channelKey];
    final priorityMap = Map<String, int>.from(
      existing?.priorityLastUsedMs ?? const {},
    )..[priorityId] = now;
    next[channelKey] = ConnectionMruEntry(
      lastUsedMs: now,
      priorityLastUsedMs: priorityMap,
    );
    emit(state.copyWith(connectionMru: next));
    await _persistConnectionMru();
  }

  /// Reorder [keys] by MRU. Bucket 1: keys with a recorded use in
  /// [priorityId], sorted by that priority's timestamp descending. Bucket 2:
  /// remaining keys with any recorded use, sorted by global timestamp
  /// descending. Bucket 3: keys with no recorded use, preserving their
  /// position in [keys].
  List<String> rankConnectionsByMru({
    required List<String> keys,
    required String priorityId,
  }) {
    final mru = state.connectionMru;
    final priorityBucket = <String>[];
    final globalBucket = <String>[];
    final unseenBucket = <String>[];
    for (final key in keys) {
      final entry = mru[key];
      if (entry == null) {
        unseenBucket.add(key);
        continue;
      }
      if (entry.priorityLastUsedMs.containsKey(priorityId)) {
        priorityBucket.add(key);
      } else {
        globalBucket.add(key);
      }
    }
    priorityBucket.sort((a, b) {
      final at = mru[a]!.priorityLastUsedMs[priorityId]!;
      final bt = mru[b]!.priorityLastUsedMs[priorityId]!;
      return bt.compareTo(at);
    });
    globalBucket.sort(
      (a, b) => mru[b]!.lastUsedMs.compareTo(mru[a]!.lastUsedMs),
    );
    return [...priorityBucket, ...globalBucket, ...unseenBucket];
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

  /// Returns the MRU-ordered list of sub-types for this priority.
  /// If no stored value, returns the default order.
  List<ThreadSubType> getSubTypeMru(String priorityId) {
    final prefs = ProfilePreferences.instance;
    final stored = prefs.getString('$_kSubTypeMruPrefix$priorityId');
    if (stored != null && stored.isNotEmpty) {
      final names = stored.split(',');
      final result = <ThreadSubType>[];
      for (final name in names) {
        final subType = ThreadSubType.values.firstWhereOrNull(
          (t) => t.value == name,
        );
        if (subType != null) result.add(subType);
      }
      // Add any missing sub-types at the end (e.g. newly added types)
      for (final t in ThreadSubType.values) {
        if (!result.contains(t)) result.add(t);
      }
      return result;
    }
    return ThreadSubType.values.toList();
  }

  /// Moves [subType] to position 0 in the priority's MRU list and persists.
  Future<void> recordSubTypeMru(
    String priorityId,
    ThreadSubType subType,
  ) async {
    final current = getSubTypeMru(priorityId);
    current.remove(subType);
    current.insert(0, subType);
    final prefs = ProfilePreferences.instance;
    await prefs.setString(
      '$_kSubTypeMruPrefix$priorityId',
      current.map((t) => t.value).join(','),
    );
  }

  /// Load state from profile preferences
  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    final idsString = prefs.getString(_kMentionMruKey);
    final showAllPriorities = prefs.getBool(_kShowAllPrioritiesKey) ?? false;

    final mruJson = prefs.getString(_kConnectionMruKey);
    Map<String, ConnectionMruEntry> connectionMru = const {};
    if (mruJson != null && mruJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(mruJson) as Map<String, dynamic>;
        connectionMru = decoded.map(
          (k, v) => MapEntry(
            k,
            ConnectionMruEntry.fromJson(v as Map<String, dynamic>),
          ),
        );
      } catch (_) {
        connectionMru = const {};
      }
    }

    emit(state.copyWith(
      mentionMruIds: idsString != null && idsString.isNotEmpty
          ? idsString.split(',')
          : null,
      showAllPriorities: showAllPriorities,
      connectionMru: connectionMru,
    ));
  }

  /// Persist state to profile preferences
  Future<void> _persistState() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(_kMentionMruKey, state.mentionMruIds.join(','));
    await prefs.setBool(_kShowAllPrioritiesKey, state.showAllPriorities);
  }

  Future<void> _persistConnectionMru() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(
      _kConnectionMruKey,
      jsonEncode(
        state.connectionMru.map((k, v) => MapEntry(k, v.toJson())),
      ),
    );
  }
}
