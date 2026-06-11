import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/profile_preferences.dart';
import 'onboarding_hoverable.dart';
import 'onboarding_steps.dart';
import 'onboarding_progress.dart';

/// Renders a highlight onboarding step.
///
/// On desktop: full-screen overlay with blur + colored tint and a cutout
/// revealing the target panel. Content is placed on the overlay.
///
/// On mobile: screen split horizontally — top half shows the highlighted
/// tab content, bottom half is the colored overlay with onboarding content.
class OnboardingHighlight extends StatelessWidget {
  const OnboardingHighlight({
    required this.step,
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    required this.onDismiss,
    this.onBack,
    super.key,
  });

  final HighlightStep step;
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback onDismiss;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (layoutState.multiPanel) {
          return _DesktopHighlight(
            step: step,
            currentStep: currentStep,
            totalSteps: totalSteps,
            onNext: onNext,
            onBack: onBack,
            onDismiss: onDismiss,
            layoutState: layoutState,
          );
        }
        return _MobileHighlight(
          step: step,
          currentStep: currentStep,
          totalSteps: totalSteps,
          onNext: onNext,
          onBack: onBack,
          onDismiss: onDismiss,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop: blur + tint overlay with panel cutout
// ---------------------------------------------------------------------------

class _DesktopHighlight extends StatelessWidget {
  const _DesktopHighlight({
    required this.step,
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    required this.onDismiss,
    required this.layoutState,
    this.onBack,
  });

  final HighlightStep step;
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback onDismiss;
  final VoidCallback? onBack;
  final LayoutState layoutState;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final cutout = _computeCutoutRect(size, layoutState, step.target);

        // Content always goes on the side of the cutout that has space — the
        // opposite side from the cutout itself. [nearCutout] keeps it on the
        // same side but pushes it toward the cutout so the text reads as
        // attached to the highlighted panel instead of crowding the
        // viewport edge.
        final contentOnRight = cutout.left < size.width / 2;
        final isNear = step.multiPanelAlignment ==
            MultiPanelContentAlignment.nearCutout;

        final areaLeft = contentOnRight ? cutout.right + 40 : 40.0;
        final areaWidth = contentOnRight
            ? size.width - cutout.right - 80
            : cutout.left - 80;
        final contentWidth = areaWidth.clamp(200.0, 400.0);
        // When pulling toward the cutout, right-align the box in the
        // available area if the cutout is to its right, otherwise it's
        // already flush left against the cutout.
        final contentLeft = isNear && !contentOnRight
            ? areaLeft + (areaWidth - contentWidth)
            : areaLeft;

        final mainAxis = switch (step.multiPanelAlignment) {
          MultiPanelContentAlignment.top => MainAxisAlignment.start,
          MultiPanelContentAlignment.bottom => MainAxisAlignment.end,
          MultiPanelContentAlignment.center ||
          MultiPanelContentAlignment.nearCutout =>
            MainAxisAlignment.center,
        };

        // See FullScreenStep backdrop: in dark mode this mid-tone lightness
        // keeps the highlight tint vibrant once it's blended over the blurred
        // panel. In light mode the same tint blends over a near-white feed and
        // washes out, leaving the white overlay text low-contrast — so darken
        // the tint and push its opacity up to keep the copy legible.
        final isLight = context.colour.brightness == Brightness.light;
        final tint = context.colour.colours
            .fromTheme(step.overlay, lightness: isLight ? 0.48 : 0.55);

        return Stack(
          children: [
            // Blur + tint overlay with cutout
            ClipPath(
              clipper: _CutoutClipper(cutout),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                child: Container(
                  color: tint.withValues(alpha: isLight ? 0.85 : 0.65),
                ),
              ),
            ),
            // X dismiss — upper-right of the coloured (dimmed) region that
            // holds the onboarding content, never over the highlighted cutout.
            // When the content sits on the right, that region runs to the
            // screen edge (right: 16). When the cutout is the right panel and
            // the content sits to its left, the coloured region ends at the
            // cutout's left edge, so anchor the X just inside it instead.
            Positioned(
              top: 16,
              right: contentOnRight ? 16.0 : size.width - cutout.left + 16,
              child: OnboardingHoverable(
                onTap: onDismiss,
                builder: (context, hovered) =>
                    _DismissButton(hovered: hovered),
              ),
            ),
            // Content on the overlay. Top/bottom variants leave breathing
            // room from the screen edge so the text doesn't crash into the
            // dismiss button or the bottom of the viewport.
            Positioned(
              left: contentLeft,
              top: 64,
              bottom: 32,
              width: contentWidth,
              child: Column(
                mainAxisAlignment: mainAxis,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title + body (+ optional content) scroll within the
                  // fixed-height overlay so a tall content builder — e.g. the
                  // sample-focus chips — never overflows. With no builder the
                  // block is short and still hugs the chosen anchor edge.
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            step.title,
                            style: const TextStyle(
                              color: Color(0xFFFFFFFF),
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            step.body,
                            style: const TextStyle(
                              color: Color(0xE6FFFFFF),
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              decoration: TextDecoration.none,
                              height: 1.6,
                            ),
                          ),
                          if (step.contentBuilder != null) ...[
                            const SizedBox(height: 24),
                            step.contentBuilder!(context),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  OnboardingProgress(
                    currentStep: currentStep,
                    totalSteps: totalSteps,
                    onNext: onNext,
                    onBack: onBack,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Compute the rectangle to cut out of the overlay for the given target.
Rect _computeCutoutRect(
  Size screenSize,
  LayoutState layoutState,
  HighlightTarget target,
) {
  final prefs = ProfilePreferences.instance;
  final savedLeftWidth = prefs.getDouble('layout_left_panel_width') ?? 280.0;
  final leftWidth = savedLeftWidth < LayoutState.leftPanelMinWidth
      ? 280.0
      : savedLeftWidth;
  final middleRatio = prefs.getDouble('layout_middle_panel_ratio') ?? 0.5;

  final totalWidth = screenSize.width;
  final height = screenSize.height;

  // Compute effective panel widths (mirrors ResizablePanelLayout logic)
  double effectiveLeft = 0;
  double effectiveMiddle = 0;

  if (layoutState.leftPanelVisible) {
    final minForOthers = layoutState.middlePanelVisible
        ? LayoutState.middlePanelMinWidth + LayoutState.rightPanelMinWidth
        : LayoutState.middlePanelMinWidth;
    final maxLeft = (totalWidth - minForOthers).clamp(0.0, double.infinity);
    effectiveLeft = leftWidth.clamp(0.0, maxLeft);
    if (effectiveLeft < LayoutState.leftPanelMinWidth) effectiveLeft = 0;
  }

  if (layoutState.middlePanelVisible) {
    final remaining = totalWidth - effectiveLeft;
    final desired = remaining * middleRatio;
    final maxMiddle =
        (remaining - LayoutState.rightPanelMinWidth).clamp(0.0, double.infinity);
    effectiveMiddle = desired.clamp(0.0, maxMiddle);
    if (effectiveMiddle < LayoutState.middlePanelMinWidth) effectiveMiddle = 0;
  }

  final panelTarget = target is PanelTarget ? target : null;
  // ThreadTarget and NamedThreadTarget both highlight the right panel on
  // desktop — the latter just defers thread resolution to runtime.
  final isRightPanel = target is ThreadTarget ||
      target is NamedThreadTarget ||
      panelTarget == PanelTarget.newThread;
  // Agenda lives in the left panel below priorities in multi-panel mode
  // (see `PriorityPage`'s `ResizablePanelLayout(leftBottom: …)`), so we cut
  // out the whole left panel for both agenda and priorities steps and rely
  // on the step's content alignment to anchor next to the relevant section.
  final isLeftPanel = panelTarget == PanelTarget.priorities ||
      panelTarget == PanelTarget.agenda;
  final isMiddlePanel = panelTarget == PanelTarget.feed;

  if (isLeftPanel && effectiveLeft > 0) {
    return Rect.fromLTWH(0, 0, effectiveLeft, height);
  }
  if (isMiddlePanel && effectiveMiddle > 0) {
    return Rect.fromLTWH(effectiveLeft, 0, effectiveMiddle, height);
  }
  if (isRightPanel) {
    final rightLeft = effectiveLeft + effectiveMiddle;
    final rightWidth =
        (totalWidth - rightLeft).clamp(0.0, double.infinity);
    return Rect.fromLTWH(rightLeft, 0, rightWidth, height);
  }

  // Fallback: highlight the full screen (shouldn't happen)
  return Rect.fromLTWH(0, 0, totalWidth, height);
}

/// Custom clipper that fills everything except [cutout].
class _CutoutClipper extends CustomClipper<Path> {
  const _CutoutClipper(this.cutout);

  final Rect cutout;

  @override
  Path getClip(Size size) {
    return Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(cutout, const Radius.circular(8)))
      ..fillType = PathFillType.evenOdd;
  }

  @override
  bool shouldReclip(_CutoutClipper oldClipper) => cutout != oldClipper.cutout;
}

// ---------------------------------------------------------------------------
// Mobile: horizontal split — top = highlighted area, bottom = overlay content
// ---------------------------------------------------------------------------

class _MobileHighlight extends StatelessWidget {
  const _MobileHighlight({
    required this.step,
    required this.currentStep,
    required this.totalSteps,
    required this.onNext,
    required this.onDismiss,
    this.onBack,
  });

  final HighlightStep step;
  final int currentStep;
  final int totalSteps;
  final VoidCallback onNext;
  final VoidCallback onDismiss;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    // Light mode blends this tint over a near-white app background, washing it
    // out and leaving the white overlay text low-contrast. Darken the tint and
    // raise its opacity so the copy stays legible (matches _DesktopHighlight).
    final isLight = context.colour.brightness == Brightness.light;
    final tint = context.colour.colours
        .fromTheme(step.overlay, lightness: isLight ? 0.48 : 0.55);
    return Column(
      children: [
        // Top half: transparent — shows highlighted app content beneath
        const Expanded(child: SizedBox.expand()),
        // Bottom half: colored overlay with content
        Expanded(
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                color: tint.withValues(alpha: isLight ? 0.92 : 0.85),
                child: SafeArea(
                  top: false,
                  child: Stack(
                    children: [
                      // X dismiss — top right of this area
                      Positioned(
                        top: 8,
                        right: 12,
                        child: OnboardingHoverable(
                          onTap: onDismiss,
                          builder: (context, hovered) =>
                              _DismissButton(hovered: hovered),
                        ),
                      ),
                      // Content + progress
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      step.title,
                                      style: const TextStyle(
                                        color: Color(0xFFFFFFFF),
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                        decoration: TextDecoration.none,
                                        height: 1.3,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      step.body,
                                      style: const TextStyle(
                                        color: Color(0xE6FFFFFF),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        decoration: TextDecoration.none,
                                        height: 1.6,
                                      ),
                                    ),
                                    if (step.contentBuilder != null) ...[
                                      const SizedBox(height: 20),
                                      step.contentBuilder!(context),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            OnboardingProgress(
                              currentStep: currentStep,
                              totalSteps: totalSteps,
                              onNext: onNext,
                              onBack: onBack,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared dismiss button
// ---------------------------------------------------------------------------

class _DismissButton extends StatelessWidget {
  const _DismissButton({this.hovered = false});

  final bool hovered;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: hovered ? const Color(0x26FFFFFF) : const Color(0x00FFFFFF),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '\u00D7',
          style: TextStyle(
            color: hovered
                ? const Color(0xFFFFFFFF)
                : const Color(0xB3FFFFFF),
            fontSize: 24,
            fontWeight: FontWeight.w300,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
