import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'onboarding_hoverable.dart';

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

  /// Tapping Next. When null, the Next button is shown disabled (greyed and
  /// non-interactive) — used by required-field steps until the field is valid.
  final VoidCallback? onNext;

  /// Provided when there's a previous step to return to. When null, the
  /// back chevron is hidden — used on the first step.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
        // Back chevron — subtle, only visible when there's somewhere to go
        // back to. Reserves the same width when hidden so the dots stay
        // centered as the user advances.
        SizedBox(
          width: 28,
          height: 28,
          child: onBack != null
              ? OnboardingHoverable(
                  onTap: onBack!,
                  builder: (context, hovered) => AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    decoration: BoxDecoration(
                      color: hovered
                          ? const Color(0x26FFFFFF)
                          : const Color(0x00FFFFFF),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Icon(
                        FontAwesomeIcons.chevronLeft,
                        size: 14,
                        color: hovered
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xB3FFFFFF),
                      ),
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
        // Next button. Disabled (greyed, non-interactive) when [onNext] is null
        // — a required-field step that isn't valid yet.
        Opacity(
          opacity: onNext == null ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: onNext == null,
            child: OnboardingHoverable(
              onTap: onNext ?? () {},
              builder: (context, hovered) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: hovered
                      ? const Color(0xFFE8E5FF)
                      : const Color(0xFFFFFFFF),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: hovered
                      ? const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 12,
                            offset: Offset(0, 2),
                          ),
                        ]
                      : null,
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
          ),
        ),
        ],
      ),
    );
  }
}
