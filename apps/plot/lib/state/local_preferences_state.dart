part of 'local_preferences.dart';

/// MRU entry for a single connection channel key.
///
/// Tracks both the global most-recent-use timestamp and per-priority
/// most-recent-use timestamps so rankings can be biased toward whichever
/// priority the user is currently filing into.
class ConnectionMruEntry extends Equatable {
  const ConnectionMruEntry({
    required this.lastUsedMs,
    required this.priorityLastUsedMs,
  });

  final int lastUsedMs;
  final Map<String, int> priorityLastUsedMs;

  ConnectionMruEntry copyWith({
    int? lastUsedMs,
    Map<String, int>? priorityLastUsedMs,
  }) =>
      ConnectionMruEntry(
        lastUsedMs: lastUsedMs ?? this.lastUsedMs,
        priorityLastUsedMs: priorityLastUsedMs ?? this.priorityLastUsedMs,
      );

  Map<String, dynamic> toJson() => {
        'lastUsedMs': lastUsedMs,
        'priorityLastUsedMs': priorityLastUsedMs,
      };

  factory ConnectionMruEntry.fromJson(Map<String, dynamic> json) =>
      ConnectionMruEntry(
        lastUsedMs: (json['lastUsedMs'] as num).toInt(),
        priorityLastUsedMs: (json['priorityLastUsedMs'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      );

  @override
  List<Object?> get props => [lastUsedMs, priorityLastUsedMs];
}

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
    this.showAllPriorities = false,
    this.connectionMru = const {},
  });

  /// Most-recently-used mention IDs (TwistInstance IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Whether to show all priorities (active + archived) or active only
  /// false = active only (default), true = show all
  final bool showAllPriorities;

  /// MRU of connection channel keys (`CreateTarget.key`), keyed by channel key.
  final Map<String, ConnectionMruEntry> connectionMru;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
    bool? showAllPriorities,
    Map<String, ConnectionMruEntry>? connectionMru,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
      showAllPriorities: showAllPriorities ?? this.showAllPriorities,
      connectionMru: connectionMru ?? this.connectionMru,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds, showAllPriorities, connectionMru];
}
