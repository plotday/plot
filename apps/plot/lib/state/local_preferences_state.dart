part of 'local_preferences.dart';

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
  });

  /// Most-recently-used mention IDs (PriorityTwist IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds];
}
