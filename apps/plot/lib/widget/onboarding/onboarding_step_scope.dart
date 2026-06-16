import 'package:flutter/widgets.dart';

/// Exposes the active full-screen step's "advance" action — the same
/// commit-hooks-then-next flow the pager's Next button runs — to descendant
/// step content. Lets interactive content (e.g. the role picker) advance the
/// moment the user makes a choice, instead of requiring a separate Next tap.
///
/// [maybeOf] returns null when no scope is present (e.g. a widget test that
/// pumps the content in isolation), so callers null-check and fall back to
/// plain selection.
class OnboardingStepScope extends InheritedWidget {
  const OnboardingStepScope({
    required this.advance,
    required super.child,
    super.key,
  });

  /// Runs the current step's `onBeforeNext` hook (if any) then advances to the
  /// next visible step. Async because the commit hook may do I/O.
  final Future<void> Function() advance;

  static Future<void> Function()? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<OnboardingStepScope>()?.advance;

  @override
  bool updateShouldNotify(OnboardingStepScope oldWidget) =>
      advance != oldWidget.advance;
}
