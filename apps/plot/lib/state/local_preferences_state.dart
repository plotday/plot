part of 'local_preferences.dart';

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
    this.showAllPriorities = false,
  });

  /// Most-recently-used mention IDs (TwistInstance IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Whether to show all priorities (active + archived) or active only
  /// false = active only (default), true = show all
  final bool showAllPriorities;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
    bool? showAllPriorities,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
      showAllPriorities: showAllPriorities ?? this.showAllPriorities,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds, showAllPriorities];
}
