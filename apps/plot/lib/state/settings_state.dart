part of 'settings.dart';

/// Immutable settings state
class SettingsState extends Equatable {
  const SettingsState({
    this.enterBehavior = EnterBehavior.enterSubmits,
    this.hasBeenPromptedForEnterBehavior = false,
  });

  /// Current enter key behavior preference
  final EnterBehavior enterBehavior;

  /// Whether the user has been prompted for their enter key preference
  final bool hasBeenPromptedForEnterBehavior;

  /// Create a copy with updated properties
  SettingsState copyWith({
    EnterBehavior? enterBehavior,
    bool? hasBeenPromptedForEnterBehavior,
  }) {
    return SettingsState(
      enterBehavior: enterBehavior ?? this.enterBehavior,
      hasBeenPromptedForEnterBehavior: hasBeenPromptedForEnterBehavior ??
          this.hasBeenPromptedForEnterBehavior,
    );
  }

  @override
  List<Object?> get props => [enterBehavior, hasBeenPromptedForEnterBehavior];
}
