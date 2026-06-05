import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
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

    return BlocListener<OnboardingBloc, OnboardingState>(
      // Only fire on the explicit Finish — Next on the last step. The
      // dismiss (X) button also drives the same OnboardingCompleted
      // transition, but a user who quits mid-flow shouldn't be yanked
      // away from whatever screen they were inspecting at the time.
      listenWhen: (previous, current) =>
          previous is OnboardingActive &&
          previous.isLastStep &&
          current is OnboardingCompleted,
      listener: (context, _) => _navigateAfterFinish(context),
      child: BlocBuilder<OnboardingBloc, OnboardingState>(
        builder: (context, state) {
          final isActive = state is OnboardingActive;

          // Build the overlay contents only when active. Both the backdrop
          // and foreground layers below are always mounted so the very first
          // appearance fades in rather than popping. The backdrop's color
          // tweens to opaque quickly (independently of the foreground's
          // opacity fade) so the app UI behind is hidden before the calm
          // foreground reveal — without this, a single AnimatedOpacity over
          // both would leave the app UI bleeding through the half-faded
          // backdrop during the transition.
          Color backdropColor = const Color(0x00000000);
          Widget foreground = const SizedBox.shrink();
          if (isActive) {
            final step = state.step;
            final bloc = context.read<OnboardingBloc>();
            final onNext = bloc.next;
            final onDismiss = bloc.dismiss;
            final onBack = state.currentStep > 0 ? bloc.previous : null;

            // The opaque backdrop sits above the app content and below the
            // step's foreground. Keeping it as a single persistent layer
            // (the child swap is via AnimatedSwitcher only on the
            // foreground) means the color animates smoothly between
            // full-screen steps without a mid-transition window where both
            // old and new are partially transparent and the app UI bleeds
            // through.
            //
            // For HighlightStep we drop to fully transparent so the panel
            // cutout actually reveals the app — the highlight widget paints
            // its own tinted overlay with a clipped hole.
            //
            // Hero backdrops use a fixed mid-tone lightness rather than the
            // theme's small-accent default — full-screen colour behind white
            // text wants more vibrancy than the button-sized accent value.
            backdropColor = step is FullScreenStep
                ? context.colour.colours.fromTheme(
                    step.background,
                    lightness: 0.55,
                  )
                : const Color(0x00000000);

            // If the step points at a NamedThreadTarget (a thread looked up
            // by title within a priority), resolve it from the local store
            // and route the right panel to it. Done in a post-frame callback
            // so we don't trigger navigation mid-build.
            if (step is HighlightStep && step.target is NamedThreadTarget) {
              final target = step.target as NamedThreadTarget;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(_navigateToNamedThread(target));
              });
            }

            // In single-panel mode each highlight step needs to route to the
            // screen it's describing — otherwise the transparent top half of
            // [_MobileHighlight] reveals the previous step's screen (or the
            // initial /agenda landing) instead of the one the copy is about.
            // Multi-panel skips this entirely: every panel is already on
            // screen at once.
            if (step is HighlightStep && step.target is PanelTarget) {
              final target = step.target as PanelTarget;
              final layoutBloc = context.read<LayoutBloc?>();
              final multiPanel = layoutBloc?.state.multiPanel ?? false;
              if (!multiPanel) {
                final (PageRouteInfo<dynamic>?, String?) destination =
                    _singlePanelDestination(context, target);
                final route = destination.$1;
                final expectedPath = destination.$2;
                if (route != null && expectedPath != null) {
                  final ctx = navigatorKey?.currentContext;
                  if (ctx != null &&
                      ctx.mounted &&
                      ctx.router.currentPath != expectedPath) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (ctx.mounted) {
                        ctx.router.navigate(route);
                      }
                    });
                  }
                }
              }
            }

            Widget? overlay;
            if (step is FullScreenStep) {
              // Full-screen steps render their content inside an
              // AnimatedSwitcher (managed by [_FullScreenLayer]) but the
              // pager sits outside it, so it persists across step swaps and
              // the active dot smoothly slides to the next position via its
              // existing AnimatedContainer.
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
              // Override the inherited DefaultTextStyle so descendants don't
              // fall back to Flutter's debug yellow-underline style. The
              // overlay sits outside the app's Scaffold (which provides this
              // via material.Material), so without this, any Text in the
              // overlay tree that doesn't explicitly set `decoration` shows
              // the debug underline on Android.
              foreground = DefaultTextStyle.merge(
                style: const TextStyle(decoration: TextDecoration.none),
                child: overlay,
              );
            }
          }

          return Stack(
            children: [
              child,
              // Solid backdrop — sits outside the AnimatedOpacity so its
              // alpha is controlled by the color tween, not layer opacity.
              // Tweens quickly to opaque so the app UI is hidden before the
              // foreground starts becoming visible. The same AnimatedContainer
              // also handles step-to-step color transitions between
              // FullScreenSteps.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    color: backdropColor,
                  ),
                ),
              ),
              // Foreground content (text, illustration, buttons) fades in
              // on top of the now-opaque backdrop.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !isActive,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                    opacity: isActive ? 1.0 : 0.0,
                    child: foreground,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Navigates to the root priority after the user explicitly finishes
  /// onboarding (Next on the last step). Without this, the user is left
  /// on whatever the final highlight step navigated them to — typically
  /// the seeded "Everything in its place" thread — instead of a useful
  /// starting point.
  ///
  /// PriorityOnlyRoute (mounted as the empty-path child of PriorityRoute)
  /// handles single vs multi-panel automatically: single-panel renders
  /// the activity feed; multi-panel redirects to NewThreadRoute so the
  /// right panel shows the empty thread editor.
  void _navigateAfterFinish(BuildContext context) {
    final nowState = context.read<NowBloc>().state;
    if (nowState is! NowLoaded) return;
    // `defaultPriority` orders `root DESC` then `created_at ASC`, so it
    // resolves to the user's root priority — the "land here" target the
    // bottom-nav Activity tap also uses for the cold-start case.
    final pidStr = nowState.defaultPriority.id.toShortString();
    final ctx = navigatorKey?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    ctx.router.navigate(PriorityRoute(priorityIdString: pidStr));
  }

  /// Returns the destination route + canonical path for the single-panel
  /// view of [target]. Path is used to short-circuit no-op navigations
  /// (post-frame callbacks fire on every rebuild). Returns `(null, null)`
  /// when the underlying state isn't ready yet (e.g. NowBloc still
  /// loading) — the next bloc rebuild will retry.
  (PageRouteInfo<dynamic>?, String?) _singlePanelDestination(
    BuildContext context,
    PanelTarget target,
  ) {
    switch (target) {
      case PanelTarget.priorities:
        return (const PrioritiesRoute(), '/priorities');
      case PanelTarget.agenda:
        // The agenda is hidden when the user has no active calendar
        // connection; navigating to /agenda would bounce back through `/`
        // and loop. Target Focuses directly so onboarding's repeated
        // (path-gated) navigation settles instead of looping.
        if (!TwistInstance.hasCalendarConnectionInCache) {
          return (const PrioritiesRoute(), '/priorities');
        }
        return (const AgendaRoute(), '/agenda');
      case PanelTarget.feed:
        final nowState = context.read<NowBloc>().state;
        if (nowState is! NowLoaded) return (null, null);
        final priority = nowState.context ?? nowState.defaultPriority;
        final pidStr = priority.id.toShortString();
        return (PriorityRoute(priorityIdString: pidStr), '/p/$pidStr');
      case PanelTarget.newThread:
        return (null, null);
    }
  }

  Future<void> _navigateToNamedThread(NamedThreadTarget target) async {
    try {
      // Onboarding threads live in the user's Inbox (root) now, so resolve the
      // target thread there rather than under a named focus.
      final priorityRow =
          await (Store.get.select(Store.get.priorities)
                ..where((tbl) => tbl.root.equals(true))
                ..where((tbl) => tbl.archivedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
      if (priorityRow == null) return;

      final threadRow =
          await (Store.get.select(Store.get.threads)
                ..where(
                  (tbl) => tbl.priorityId.equals(priorityRow.id.toBytes()),
                )
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
      // ThreadRoute lives at `/p/:priorityId/:threadId`, so a root-level
      // push with just a threadId can't fill the `:priorityId` parent
      // segment and crashes with "Failed to parse [String] priorityId
      // value from null" — leaving the underlying screen blank (most
      // visible in single-panel mode where there's no fallback layout).
      //
      // Two paths depending on whether PriorityRoute is already mounted:
      //
      //   1. Multi-panel: PriorityRoute is alive on the Activity stack.
      //      Push ThreadRoute on its inner router so the priority
      //      context (BlocProvider, panel layout) doesn't tear down.
      //      `navigate(PriorityRoute(children: [...]))` would drop the
      //      inner child here — see the comment on `_openNewThread` in
      //      `priorities_shell.dart`.
      //
      //   2. Single-panel (or no PriorityRoute mounted): build the
      //      nested form explicitly so both layers mount together.
      //      Mirrors [ThreadLookupPage].
      final priorityIdShort = priorityRow.id.toShortString();
      final innerRouter = _findPriorityInnerRouter(ctx.router.root);
      if (innerRouter != null) {
        innerRouter.push(ThreadRoute(threadIdString: shortId));
      } else {
        ctx.router.navigate(
          PriorityRoute(
            priorityIdString: priorityIdShort,
            children: [ThreadRoute(threadIdString: shortId)],
          ),
        );
      }
    } catch (e, t) {
      // The step's highlight still covers the right panel even if the
      // thread can't be found yet, so this is best-effort — but report
      // unexpected failures so a regression here doesn't go unnoticed.
      log.warning('Failed to navigate to onboarding thread', e, t);
      Tracker.captureException(e, t);
    }
  }

  /// Walks the controller tree to find the [StackRouter] hosted by the
  /// active [PriorityRoute]. Mirrors the helper in [PrioritiesShell] —
  /// [RoutingController.innerRouterOf] is non-recursive, so a deeply
  /// nested route (root → AppShell → tabs → ActivityShell → PriorityRoute)
  /// needs an explicit walk.
  StackRouter? _findPriorityInnerRouter(RoutingController root) {
    final direct = root.innerRouterOf<StackRouter>(PriorityRoute.name);
    if (direct != null) return direct;
    for (final child in root.childControllers) {
      final hit = _findPriorityInnerRouter(child);
      if (hit != null) return hit;
    }
    return null;
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
              final contentMinHeight = constraints.maxHeight - pagerBlockHeight;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: contentMinHeight > 0 ? contentMinHeight : 0,
                      ),
                      child: Padding(
                        // X button clearance (40px button at top:16).
                        padding: const EdgeInsets.only(top: 56),
                        child: Center(
                          // Per-step content cross-fades. Same
                          // asymmetric curves as the highlight branch.
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 400),
                            switchOutCurve: const Interval(
                              0.5,
                              1.0,
                              curve: Curves.easeIn,
                            ),
                            switchInCurve: const Interval(
                              0.4,
                              1.0,
                              curve: Curves.easeOut,
                            ),
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
