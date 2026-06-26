import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart' show Reaction, ThreadSubType;
import 'package:plot/util/profile_preferences.dart';

part 'local_preferences_state.dart';

/// Bloc for managing local app preferences that are not synced to the server
class LocalPreferencesBloc extends Cubit<LocalPreferencesState> {
  LocalPreferencesBloc()
      : super(const LocalPreferencesState(mentionMruIds: [])) {
    _loadFromPreferences();
  }

  // Preference keys are public so the central user-scoped-preferences registry
  // ([clearUserScopedPreferences]) can clear them on sign-out without
  // duplicating the literals. They all hold user-specific usage data and must
  // not bleed across accounts on a shared device.
  static const String kMentionMruKey = 'mention_mru_ids';
  static const String kShowAllPrioritiesKey = 'show_all_priorities';
  static const String kSubTypeMruPrefix = 'thread_subtype_mru:';
  static const String kConnectionMruKey = 'connection_mru';
  static const String kReactionMruKey = 'reaction_mru';
  static const String kLinkMruKey = 'link_mru';
  static const int _maxMruItems = 50;
  static const int _maxLinkMruItems = 100;
  static const int _maxReactionMruItems = 40;

  /// Drop all in-memory user-scoped preference state back to defaults.
  ///
  /// Called on sign-out: this bloc is provided at the app root and is NOT
  /// recreated when a different user signs in on the same device, so without
  /// this the next user would inherit the previous user's mention / connection
  /// / link MRUs (their contacts and connections). The persisted copies are
  /// cleared in the same step via `clearUserScopedPreferences`.
  void reset() => emit(const LocalPreferencesState(mentionMruIds: []));

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

  /// Record that the user just used [channelKey]. The global timestamp is
  /// always bumped to now; when [priorityId] is provided, that priority's
  /// timestamp is bumped too so the per-priority ranking
  /// ([rankConnectionsByMru]) reflects the latest use.
  ///
  /// [channelKey] is a target **signature** — for bare connector targets this
  /// equals `CreateTarget.key` (so historical entries still match), and for
  /// the two-step compose flow it may also carry a team and roster (see
  /// `composeConnectorSignature` / `composeChatSignature`). Recording a
  /// signature with a roster ranks it distinctly from the bare connector key.
  ///
  /// [priorityId] is optional because the two-step target picker ranks by the
  /// **global** MRU (no focus is chosen up front); the per-priority focus
  /// suggestion still passes it.
  Future<void> recordConnectionUsage({
    required String channelKey,
    String? priorityId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = Map<String, ConnectionMruEntry>.from(state.connectionMru);
    final existing = next[channelKey];
    final priorityMap = Map<String, int>.from(
      existing?.priorityLastUsedMs ?? const {},
    );
    if (priorityId != null) priorityMap[priorityId] = now;
    next[channelKey] = ConnectionMruEntry(
      lastUsedMs: now,
      priorityLastUsedMs: priorityMap,
    );
    emit(state.copyWith(connectionMru: next));
    await _persistConnectionMru();
  }

  /// Reorder [signatures] by **global** MRU recency (no priority bias):
  /// signatures with any recorded use sorted by global timestamp descending,
  /// then signatures with no recorded use preserving their input order.
  ///
  /// This is the ranking the two-step target picker uses — the step-1 list is
  /// globally MRU-ordered, with no focus chosen up front. (The per-priority
  /// [rankConnectionsByMru] remains for the focus-suggestion path.)
  List<String> rankSignaturesByMru({required List<String> signatures}) {
    final mru = state.connectionMru;
    final seen = <String>[];
    final unseen = <String>[];
    for (final sig in signatures) {
      if (mru.containsKey(sig)) {
        seen.add(sig);
      } else {
        unseen.add(sig);
      }
    }
    seen.sort((a, b) => mru[b]!.lastUsedMs.compareTo(mru[a]!.lastUsedMs));
    return [...seen, ...unseen];
  }

  /// The global most-recent-use timestamp recorded for [signature], or null
  /// when it has never been used. Lets the materialized target list order
  /// used combinations by recency and interleave templates correctly.
  int? lastUsedMsForSignature(String signature) =>
      state.connectionMru[signature]?.lastUsedMs;

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

  /// The highest-ranked connection key among [candidateKeys] that has a
  /// recorded use, biased per [rankConnectionsByMru] (priority-bucket beats
  /// global-bucket). Returns null when none of the candidates has ever been
  /// used, so callers can keep their existing default (e.g. "Plot thread").
  String? lastUsedConnectionKey({
    required List<String> candidateKeys,
    required String priorityId,
  }) {
    final ranked = rankConnectionsByMru(
      keys: candidateKeys,
      priorityId: priorityId,
    );
    if (ranked.isEmpty) return null;
    final top = ranked.first;
    // Unseen keys sort last, so a seen first key means at least one candidate
    // has history. Guard explicitly in case every candidate is unseen.
    return state.connectionMru.containsKey(top) ? top : null;
  }

  /// Record that the user just attached a link to a thread filed at
  /// [signature] (a target **signature** (`ComposeTarget.signature`)). Bumps its link-MRU timestamp.
  Future<void> recordLinkUsage(String signature) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = Map<String, int>.from(state.linkMru);
    next[signature] = now;
    // Cap: drop the oldest entries beyond the limit so the map can't grow
    // unbounded across a long-lived profile.
    if (next.length > _maxLinkMruItems) {
      final ordered = next.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      next
        ..clear()
        ..addEntries(ordered.take(_maxLinkMruItems));
    }
    emit(state.copyWith(linkMru: next));
    await _persistLinkMru();
  }

  /// Reorder [signatures] by link-MRU recency: signatures with a recorded link
  /// use sorted by timestamp descending, then signatures with no recorded use
  /// preserving their input order. Mirrors [rankSignaturesByMru].
  List<String> rankByLinkMru({required List<String> signatures}) {
    final mru = state.linkMru;
    final seen = <String>[];
    final unseen = <String>[];
    for (final sig in signatures) {
      if (mru.containsKey(sig)) {
        seen.add(sig);
      } else {
        unseen.add(sig);
      }
    }
    seen.sort((a, b) => mru[b]!.compareTo(mru[a]!));
    return [...seen, ...unseen];
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

  /// Record usage of an emoji reaction, moving it to the front of the MRU.
  /// Persists to profile preferences as a CSV of grapheme clusters.
  Future<void> recordReactionUsage(Reaction emoji) async {
    final current = List<Reaction>.from(state.reactionMru);
    current.remove(emoji);
    current.insert(0, emoji);
    if (current.length > _maxReactionMruItems) {
      current.removeRange(_maxReactionMruItems, current.length);
    }
    emit(state.copyWith(reactionMru: current));
    await _persistReactionMru();
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
    final stored = prefs.getString('$kSubTypeMruPrefix$priorityId');
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
      '$kSubTypeMruPrefix$priorityId',
      current.map((t) => t.value).join(','),
    );
  }

  /// Load state from profile preferences
  Future<void> _loadFromPreferences() async {
    final prefs = ProfilePreferences.instance;
    final idsString = prefs.getString(kMentionMruKey);
    final showAllPriorities = prefs.getBool(kShowAllPrioritiesKey) ?? false;

    final mruJson = prefs.getString(kConnectionMruKey);
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

    final reactionString = prefs.getString(kReactionMruKey);
    List<Reaction> reactionMru = const [];
    if (reactionString != null && reactionString.isNotEmpty) {
      try {
        final decoded = jsonDecode(reactionString);
        if (decoded is List) {
          reactionMru = decoded.whereType<Reaction>().toList();
        }
      } catch (_) {
        reactionMru = const [];
      }
    }

    final linkMruJson = prefs.getString(kLinkMruKey);
    Map<String, int> linkMru = const {};
    if (linkMruJson != null && linkMruJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(linkMruJson) as Map<String, dynamic>;
        linkMru = decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (_) {
        linkMru = const {};
      }
    }

    emit(state.copyWith(
      mentionMruIds: idsString != null && idsString.isNotEmpty
          ? idsString.split(',')
          : null,
      showAllPriorities: showAllPriorities,
      connectionMru: connectionMru,
      reactionMru: reactionMru,
      linkMru: linkMru,
    ));
  }

  /// Persist state to profile preferences
  Future<void> _persistState() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(kMentionMruKey, state.mentionMruIds.join(','));
    await prefs.setBool(kShowAllPrioritiesKey, state.showAllPriorities);
  }

  Future<void> _persistConnectionMru() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(
      kConnectionMruKey,
      jsonEncode(
        state.connectionMru.map((k, v) => MapEntry(k, v.toJson())),
      ),
    );
  }

  Future<void> _persistReactionMru() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(kReactionMruKey, jsonEncode(state.reactionMru));
  }

  Future<void> _persistLinkMru() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(kLinkMruKey, jsonEncode(state.linkMru));
  }
}
