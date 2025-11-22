part of 'theme.dart';

/// Theme mode options
enum AppThemeMode {
  /// Follow system theme
  system,

  /// Always use light theme
  light,

  /// Always use dark theme
  dark,
}

/// Immutable theme state
class ThemeState extends Equatable {
  const ThemeState({
    required this.mode,
    this.priorityHue = 160.0, // Default brand hue (teal/green)
  });

  /// Current theme mode preference
  final AppThemeMode mode;

  /// Current priority hue value (0-360)
  final double priorityHue;

  /// Create a copy with updated properties
  ThemeState copyWith({AppThemeMode? mode, double? priorityHue}) {
    return ThemeState(
      mode: mode ?? this.mode,
      priorityHue: priorityHue ?? this.priorityHue,
    );
  }

  @override
  List<Object?> get props => [mode, priorityHue];
}
