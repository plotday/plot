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
    this.priorityColor = const ThemeColor.defaultColor(),
  });

  /// Current theme mode preference
  final AppThemeMode mode;

  /// Current priority color
  final ThemeColor priorityColor;

  /// Get the hue value from the priority color
  double get priorityHue => priorityColor.toHue();


  /// Create a copy with updated properties
  ThemeState copyWith({AppThemeMode? mode, ThemeColor? priorityColor}) {
    return ThemeState(
      mode: mode ?? this.mode,
      priorityColor: priorityColor ?? this.priorityColor,
    );
  }

  @override
  List<Object?> get props => [mode, priorityColor];
}
