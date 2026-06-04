import 'package:flutter/widgets.dart';

import 'onboarding_steps.dart';

/// Renders a full-screen onboarding step's content column (illustration +
/// title + body + optional contentBuilder). The X dismiss button and the
/// progress pager live in [_FullScreenLayer] so they can persist across
/// step swaps and the pager can sit directly below this content in normal
/// flow rather than being absolutely positioned.
class OnboardingFullScreen extends StatelessWidget {
  const OnboardingFullScreen({required this.step, super.key});

  final FullScreenStep step;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: step.contentMaxWidth),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (step.illustrationBuilder != null) ...[
              step.illustrationBuilder!(),
              const SizedBox(height: 24),
            ],
            Text(
              step.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 28,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: Text(
                step.body,
                textAlign: TextAlign.start,
                style: const TextStyle(
                  color: Color(0xD9FFFFFF),
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  decoration: TextDecoration.none,
                  height: 1.5,
                ),
              ),
            ),
            if (step.contentBuilder != null) ...[
              const SizedBox(height: 24),
              step.contentBuilder!(context),
            ],
          ],
        ),
      ),
    );
  }
}
