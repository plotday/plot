part of 'local_preferences.dart';

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
    this.showAllPriorities = false,
    this.lastNewThreadType,
  });

  /// Most-recently-used mention IDs (PriorityTwist IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Whether to show all priorities (active + archived) or active only
  /// false = active only (default), true = show all
  final bool showAllPriorities;

  /// Last-used thread type on NewThreadPage (persisted across sessions)
  final String? lastNewThreadType;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
    bool? showAllPriorities,
    String? lastNewThreadType,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
      showAllPriorities: showAllPriorities ?? this.showAllPriorities,
      lastNewThreadType: lastNewThreadType ?? this.lastNewThreadType,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds, showAllPriorities, lastNewThreadType];
}
