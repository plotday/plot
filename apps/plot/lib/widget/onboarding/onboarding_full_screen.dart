import 'package:flutter/widgets.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/toast.dart';
import 'onboarding_steps.dart';
import 'onboarding_progress.dart';

/// Renders a full-screen onboarding page with a solid colored background.
class OnboardingFullScreen extends StatefulWidget {
  const OnboardingFullScreen({
    required this.step,
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    required this.onDismiss,
    this.onBack,
    super.key,
  });

  final FullScreenStep step;
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback onDismiss;
  final VoidCallback? onBack;

  @override
  State<OnboardingFullScreen> createState() => _OnboardingFullScreenState();
}

class _OnboardingFullScreenState extends State<OnboardingFullScreen> {
  bool _committing = false;

  Future<void> _handleNext() async {
    if (_committing) return;
    final hook = widget.step.onBeforeNext;
    if (hook == null) {
      widget.onNext();
      return;
    }
    setState(() => _committing = true);
    try {
      await hook(context);
      if (!mounted) return;
      widget.onNext();
    } catch (e, t) {
      log.warning('Onboarding step onBeforeNext failed', e, t);
      Tracker.captureException(e, t);
      if (mounted) {
        context.showToast(
          message: 'Something went wrong. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // No background color here — the parent [OnboardingOverlay] paints a
    // persistent backdrop that animates smoothly between steps. Painting
    // here too would double up during AnimatedSwitcher cross-fades and
    // reveal the app UI mid-transition.
    return SafeArea(
      child: Stack(
          children: [
            // X dismiss — upper right
            Positioned(
              top: 16,
              right: 16,
              child: GestureDetector(
                onTap: widget.onDismiss,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Text(
                      '\u00D7',
                      style: TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Centered content
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: widget.step.contentMaxWidth,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.step.illustrationBuilder != null) ...[
                        widget.step.illustrationBuilder!(),
                        const SizedBox(height: 24),
                      ],
                      Text(
                        widget.step.title,
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
                      Text(
                        widget.step.body,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xD9FFFFFF),
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          decoration: TextDecoration.none,
                          height: 1.5,
                        ),
                      ),
                      if (widget.step.contentBuilder != null) ...[
                        const SizedBox(height: 24),
                        widget.step.contentBuilder!(context),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // Progress + Next — bottom center
            Positioned(
              left: 0,
              right: 0,
              bottom: 40,
              child: Center(
                child: OnboardingProgress(
                  currentStep: widget.currentStep,
                  totalSteps: widget.totalSteps,
                  onNext: _handleNext,
                  onBack: widget.onBack,
                ),
              ),
            ),
          ],
        ),
    );
  }
}
