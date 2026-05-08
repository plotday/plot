import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// Progress dots and Next button for onboarding steps.
///
/// Shows a subtle back chevron (when [onBack] is provided), pill-shaped
/// progress dots (current step is wider), and a Next button. All rendered
/// in white for use on colored/tinted backgrounds.
class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    this.onBack,
    super.key,
  });

  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;

  /// Provided when there's a previous step to return to. When null, the
  /// back chevron is hidden — used on the first step.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Back chevron — subtle, only visible when there's somewhere to go
        // back to. Reserves the same width when hidden so the dots stay
        // centered as the user advances.
        SizedBox(
          width: 28,
          height: 28,
          child: onBack != null
              ? GestureDetector(
                  onTap: onBack,
                  behavior: HitTestBehavior.opaque,
                  child: const Center(
                    child: Icon(
                      FontAwesomeIcons.chevronLeft,
                      size: 14,
                      color: Color(0xB3FFFFFF),
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(width: 4),
        // Progress dots
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(totalSteps, (index) {
            final isCurrent = index == currentStep;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                width: isCurrent ? 20 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isCurrent
                      ? const Color(0xFFFFFFFF)
                      : const Color(0x59FFFFFF),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        ),
        const SizedBox(width: 16),
        // Next button
        GestureDetector(
          onTap: onNext,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              currentStep == totalSteps - 1 ? 'Finish' : 'Next',
              style: const TextStyle(
                color: Color(0xFF1E1B4B),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
