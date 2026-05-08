part of 'onboarding.dart';

/// State for the onboarding flow.
sealed class OnboardingState extends Equatable {
  const OnboardingState();
}

/// Onboarding has not been checked yet.
class OnboardingLoading extends OnboardingState {
  const OnboardingLoading();

  @override
  List<Object?> get props => [];
}

/// Onboarding is in progress — showing a step.
class OnboardingActive extends OnboardingState {
  const OnboardingActive({
    required this.currentStep,
    required this.steps,
  });

  final int currentStep;
  final List<OnboardingStep> steps;

  OnboardingStep get step => steps[currentStep];
  int get totalSteps => steps.length;
  bool get isLastStep => currentStep == steps.length - 1;

  @override
  List<Object?> get props => [currentStep, steps];
}

/// Onboarding is done (either completed or dismissed).
class OnboardingCompleted extends OnboardingState {
  const OnboardingCompleted();

  @override
  List<Object?> get props => [];
}
