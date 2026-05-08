import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/page/priority.dart';
import 'package:plot/router.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/logging.dart';
import 'onboarding_steps.dart';
import 'onboarding_full_screen.dart';
import 'onboarding_highlight.dart';

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

        // If the step targets the agenda or feed tab, drive the priority
        // shell's tab notifier so the panel underneath the highlight cutout
        // actually shows the right view. Defer with a post-frame callback
        // because we're inside a build and the notifier triggers rebuilds
        // in PrioritiesShell.
        if (step is HighlightStep && step.target is PanelTarget) {
          final target = step.target as PanelTarget;
          PriorityTab? tab;
          if (target == PanelTarget.agenda) tab = PriorityTab.agenda;
          if (target == PanelTarget.feed) tab = PriorityTab.activityFeed;
          if (tab != null) {
            final notifier = PriorityTabNotifier.current;
            if (notifier != null && notifier.value != tab) {
              final selected = tab;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                notifier.value = selected;
              });
            }
          }
        }

        Widget? foreground;
        if (step is FullScreenStep) {
          foreground = OnboardingFullScreen(
            key: ValueKey(state.currentStep),
            step: step,
            currentStep: state.currentStep,
            totalSteps: state.totalSteps,
            onNext: onNext,
            onBack: onBack,
            onDismiss: onDismiss,
          );
        } else if (step is HighlightStep) {
          foreground = OnboardingHighlight(
            key: ValueKey(state.currentStep),
            step: step,
            currentStep: state.currentStep,
            totalSteps: state.totalSteps,
            onNext: onNext,
            onBack: onBack,
            onDismiss: onDismiss,
          );
        }

        if (foreground != null) {
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
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: foreground,
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
