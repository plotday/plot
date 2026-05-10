import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/router.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/logging.dart';
import 'package:plot/widget/toast.dart';
import 'onboarding_steps.dart';
import 'onboarding_full_screen.dart';
import 'onboarding_highlight.dart';
import 'onboarding_hoverable.dart';
import 'onboarding_progress.dart';

/// Wraps the app's router output and conditionally shows the onboarding
/// overlay on top.
///
/// - During [OnboardingLoading] or [OnboardingCompleted], just shows [child].
/// - During [OnboardingActive], renders the appropriate step widget on top.
class OnboardingOverlay extends StatelessWidget {
  const OnboardingOverlay({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<OnboardingBloc?>();
    if (bloc == null) return child;

    return BlocBuilder<OnboardingBloc, OnboardingState>(
      builder: (context, state) {
        if (state is! OnboardingActive) return child;

        final step = state.step;
        final bloc = context.read<OnboardingBloc>();
        final onNext = bloc.next;
        final onDismiss = bloc.dismiss;
        final onBack = state.currentStep > 0 ? bloc.previous : null;

        // The opaque backdrop sits above the app content and below the
        // step's foreground. Keeping it as a single persistent layer (the
        // child swap is via AnimatedSwitcher only on the foreground) means
        // the color animates smoothly between full-screen steps without a
        // mid-transition window where both old and new are partially
        // transparent and the app UI bleeds through.
        //
        // For HighlightStep we drop to fully transparent so the panel
        // cutout actually reveals the app — the highlight widget paints its
        // own tinted overlay with a clipped hole.
        //
        // Hero backdrops use a fixed mid-tone lightness rather than the
        // theme's small-accent default — full-screen colour behind white
        // text wants more vibrancy than the button-sized accent value.
        final backdropColor = step is FullScreenStep
            ? context.colour.colours
                .fromTheme(step.background, lightness: 0.55)
            : const Color(0x00000000);

        // If the step points at a NamedThreadTarget (a thread looked up by
        // title within a priority), resolve it from the local store and
        // route the right panel to it. Done in a post-frame callback so we
        // don't trigger navigation mid-build.
        if (step is HighlightStep && step.target is NamedThreadTarget) {
          final target = step.target as NamedThreadTarget;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_navigateToNamedThread(target));
          });
        }

        // If the step targets the agenda panel, route to the dedicated
        // /agenda page so the panel underneath the highlight cutout
        // actually shows the agenda. Defer with a post-frame callback
        // because we're inside a build and navigation rebuilds the tree.
        if (step is HighlightStep && step.target is PanelTarget) {
          final target = step.target as PanelTarget;
          if (target == PanelTarget.agenda) {
            final ctx = navigatorKey?.currentContext;
            if (ctx != null &&
                ctx.mounted &&
                ctx.router.currentPath != '/agenda') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) {
                  ctx.router.push(const AgendaRoute());
                }
              });
            }
          }
          // PanelTarget.feed: PriorityPage now renders only the activity
          // feed, so no tab switch is needed — the panel is whatever is
          // currently routed.
        }

        Widget? overlay;
        if (step is FullScreenStep) {
          // Full-screen steps render their content inside an AnimatedSwitcher
          // (managed by [_FullScreenLayer]) but the pager sits outside it,
          // so it persists across step swaps and the active dot smoothly
          // slides to the next position via its existing AnimatedContainer.
          overlay = _FullScreenLayer(
            step: step,
            currentStep: state.currentStep,
            totalSteps: state.totalSteps,
            onNext: onNext,
            onBack: onBack,
            onDismiss: onDismiss,
          );
        } else if (step is HighlightStep) {
          // Asymmetric cross-fade: the outgoing foreground reaches
          // opacity 0 around the midpoint while the incoming one only
          // starts becoming visible shortly before that. Avoids the
          // muddy frame where a straight cross-fade has both layers
          // sitting at ~50% and the two designs blend together.
          overlay = AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchOutCurve: const Interval(0.5, 1.0, curve: Curves.easeIn),
            switchInCurve: const Interval(0.4, 1.0, curve: Curves.easeOut),
            child: OnboardingHighlight(
              key: ValueKey(state.currentStep),
              step: step,
              currentStep: state.currentStep,
              totalSteps: state.totalSteps,
              onNext: onNext,
              onBack: onBack,
              onDismiss: onDismiss,
            ),
          );
        }

        if (overlay != null) {
          return Stack(
            children: [
              child,
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOut,
                  color: backdropColor,
                ),
              ),
              // Override the inherited DefaultTextStyle so descendants don't
              // fall back to Flutter's debug yellow-underline style. The
              // overlay sits outside the app's Scaffold (which provides this
              // via material.Material), so without this, any Text in the
              // overlay tree that doesn't explicitly set `decoration` shows
              // the debug underline on Android.
              Positioned.fill(
                child: DefaultTextStyle.merge(
                  style: const TextStyle(decoration: TextDecoration.none),
                  child: overlay,
                ),
              ),
            ],
          );
        }

        return child;
      },
    );
  }

  Future<void> _navigateToNamedThread(NamedThreadTarget target) async {
    try {
      final priorityRow =
          await (Store.get.select(Store.get.priorities)
                ..where((tbl) => tbl.title.equals(target.priorityTitle))
                ..where((tbl) => tbl.archivedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
      if (priorityRow == null) return;

      final threadRow =
          await (Store.get.select(Store.get.threads)
                ..where((tbl) =>
                    tbl.priorityId.equals(priorityRow.id.toBytes()))
                ..where((tbl) => tbl.title.equals(target.threadTitle))
                ..where((tbl) => tbl.archivedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
      if (threadRow == null) return;

      final ctx = navigatorKey?.currentContext;
      if (ctx == null || !ctx.mounted) return;

      final shortId = threadRow.id.toShortString();
      // Skip if we're already on this thread to avoid navigation churn
      // when the bloc rebuilds for an unrelated reason.
      if (ctx.router.current.name == ThreadRoute.name &&
          ctx.router.current.params.getString('threadId') == shortId) {
        return;
      }
      await ctx.router.push(ThreadRoute(threadIdString: shortId));
    } catch (e, t) {
      // The step's highlight still covers the right panel even if the
      // thread can't be found yet, so this is best-effort — but report
      // unexpected failures so a regression here doesn't go unnoticed.
      log.warning('Failed to navigate to onboarding thread', e, t);
      Tracker.captureException(e, t);
    }
  }
}

/// Full-screen step layer. Cross-fades the per-step content (X dismiss +
/// title/body/illustration) but keeps the progress pager mounted across
/// step swaps so it doesn't fade in and out — the active dot just slides
/// to its new position via [OnboardingProgress]'s existing
/// [AnimatedContainer]. Owns the `_committing` flag because the pager's
/// Next button (now external to the content) drives [FullScreenStep.onBeforeNext].
class _FullScreenLayer extends StatefulWidget {
  const _FullScreenLayer({
    required this.step,
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    required this.onDismiss,
    this.onBack,
  });

  final FullScreenStep step;
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback onDismiss;
  final VoidCallback? onBack;

  @override
  State<_FullScreenLayer> createState() => _FullScreenLayerState();
}

class _FullScreenLayerState extends State<_FullScreenLayer> {
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
    } on OnboardingStoreUnavailable {
      // Transient: sign-out raced with the overlay. Don't capture — the
      // underlying Injector miss is environmental, not a code bug.
      log.warning('Onboarding step blocked: store not ready');
      if (mounted) {
        context.showToast(
          message: 'Still loading — please try again in a moment.',
          isError: true,
        );
      }
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
    // Single outer scroll containing both the per-step content (in an
    // AnimatedSwitcher) and the pager. The pager sits directly below the
    // content in normal flow — it scrolls with the content rather than
    // being pinned to the viewport. When content fits, the whole group
    // (content + pager) centers vertically; when it doesn't, the user
    // scrolls down to reach the pager.
    //
    // The pager is OUTSIDE the AnimatedSwitcher so it persists across
    // step swaps (no fade on the pager itself). Same goes for the X
    // dismiss button, which lives in the outer Stack.
    return SafeArea(
      child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Vertical space the pager block occupies in normal flow:
                // 32px gap above the pager + ~40px pager intrinsic
                // height + 24px breathing room below. The page content
                // is given a min-height of (viewport - this) so when
                // it's short it fills exactly the area above the pager
                // (centering within it), and when tall it grows past
                // the min and the whole column scrolls naturally.
                const pagerBlockHeight = 96.0;
                final contentMinHeight =
                    constraints.maxHeight - pagerBlockHeight;
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight:
                              contentMinHeight > 0 ? contentMinHeight : 0,
                        ),
                        child: Padding(
                          // X button clearance (40px button at top:16).
                          padding: const EdgeInsets.only(top: 56),
                          child: Center(
                            // Per-step content cross-fades. Same
                            // asymmetric curves as the highlight branch.
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              switchOutCurve: const Interval(0.5, 1.0,
                                  curve: Curves.easeIn),
                              switchInCurve: const Interval(0.4, 1.0,
                                  curve: Curves.easeOut),
                              child: OnboardingFullScreen(
                                key: ValueKey(widget.currentStep),
                                step: widget.step,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      // Persistent pager — single instance across all
                      // full-screen steps. Label flip ("Next" →
                      // "Finish") is acceptable as a one-frame change.
                      OnboardingProgress(
                        currentStep: widget.currentStep,
                        totalSteps: widget.totalSteps,
                        onNext: _handleNext,
                        onBack: widget.onBack,
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                );
              },
            ),
            // Persistent X dismiss — stays in place while the page
            // scrolls and across step swaps.
            Positioned(
              top: 16,
              right: 16,
              child: OnboardingHoverable(
                onTap: widget.onDismiss,
                builder: (context, hovered) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: hovered
                        ? const Color(0x26FFFFFF)
                        : const Color(0x00FFFFFF),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '×',
                      style: TextStyle(
                        color: hovered
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xB3FFFFFF),
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
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
