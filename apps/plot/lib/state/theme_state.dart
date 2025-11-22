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
  const ThemeState({required this.mode});

  /// Current theme mode preference
  final AppThemeMode mode;

  /// Create a copy with updated properties
  ThemeState copyWith({AppThemeMode? mode}) {
    return ThemeState(mode: mode ?? this.mode);
  }

  @override
  List<Object?> get props => [mode];
}
