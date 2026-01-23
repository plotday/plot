part of 'local_preferences.dart';

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
    this.hasSelectedWebPlatform,
  });

  /// Most-recently-used mention IDs (PriorityTwist IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Whether the user has selected to continue using the web platform
  /// null = not set (show platform picker), true = selected web
  final bool? hasSelectedWebPlatform;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
    bool? hasSelectedWebPlatform,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
      hasSelectedWebPlatform:
          hasSelectedWebPlatform ?? this.hasSelectedWebPlatform,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds, hasSelectedWebPlatform];
}
