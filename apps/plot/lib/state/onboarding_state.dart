part of 'onboarding.dart';

sealed class OnboardingState extends Equatable {
  const OnboardingState();

  @override
  List<Object?> get props => [];
}

final class OnboardingLoadingState extends OnboardingState {
  const OnboardingLoadingState();

  @override
  List<Object?> get props => [];
}

final class OnboardingProgressState extends OnboardingState {
  const OnboardingProgressState({this.loading = false});

  final bool loading;

  OnboardingProgressState copyWith({
    bool? loading,
  }) {
    return OnboardingProgressState(
      loading: loading ?? this.loading,
    );
  }

  @override
  List<Object?> get props => [];
}

final class OnboardingCompleteState extends OnboardingState {
  const OnboardingCompleteState();

  @override
  List<Object?> get props => [];
}
