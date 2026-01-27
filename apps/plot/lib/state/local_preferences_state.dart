part of 'local_preferences.dart';

/// Immutable state for local app preferences (not synced)
class LocalPreferencesState extends Equatable {
  const LocalPreferencesState({
    required this.mentionMruIds,
    this.hasSelectedWebPlatform,
    this.showAllPriorities = false,
  });

  /// Most-recently-used mention IDs (PriorityTwist IDs), ordered with most recent first
  final List<String> mentionMruIds;

  /// Whether the user has selected to continue using the web platform
  /// null = not set (show platform picker), true = selected web
  final bool? hasSelectedWebPlatform;

  /// Whether to show all priorities (active + archived) or active only
  /// false = active only (default), true = show all
  final bool showAllPriorities;

  /// Create a copy with updated properties
  LocalPreferencesState copyWith({
    List<String>? mentionMruIds,
    bool? hasSelectedWebPlatform,
    bool? showAllPriorities,
  }) {
    return LocalPreferencesState(
      mentionMruIds: mentionMruIds ?? this.mentionMruIds,
      hasSelectedWebPlatform:
          hasSelectedWebPlatform ?? this.hasSelectedWebPlatform,
      showAllPriorities: showAllPriorities ?? this.showAllPriorities,
    );
  }

  @override
  List<Object?> get props => [mentionMruIds, hasSelectedWebPlatform, showAllPriorities];
}
