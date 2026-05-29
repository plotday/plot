import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/onboarding.dart';
import 'package:plot/store/store.dart' show ThreadId;
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/onboarding/onboarding_calendars.dart';
import 'package:plot/widget/onboarding/onboarding_roles.dart';
import 'package:plot/widget/onboarding/onboarding_tools.dart';

/// A single step in the onboarding flow.
sealed class OnboardingStep {
  const OnboardingStep({required this.title, required this.body});

  final String title;
  final String body;
}

/// Full-screen page with a solid colored background.
class FullScreenStep extends OnboardingStep {
  const FullScreenStep({
    required super.title,
    required super.body,
    required this.background,
    this.illustrationBuilder,
    this.contentBuilder,
    this.contentMaxWidth = 400,
    this.onBeforeNext,
  });

  /// Story-arc theme color used as the solid hero backdrop. Resolved to a
  /// concrete RGB color at render time via the active [ColourSchemeData] so
  /// the onboarding adapts to the user's brightness and saturation settings.
  final ThemeColor background;

  /// Optional illustration widget shown above the title.
  final Widget Function()? illustrationBuilder;

  /// Optional interactive content shown below the body text.
  /// Use for auth buttons, account linking, or other actions.
  final Widget Function(BuildContext context)? contentBuilder;

  /// Maximum width for the centered content column. The default keeps the
  /// onboarding text comfortable to read; steps that lay out a grid of
  /// connector tiles bump this so the grid can use more horizontal room.
  final double contentMaxWidth;

  /// Optional async hook that runs when the user taps Next. The flow only
  /// advances when the future completes successfully — used by the roles
  /// step to commit staged priority changes before moving on.
  final Future<void> Function(BuildContext context)? onBeforeNext;
}

/// Highlight step that dims everything except a target area.
class HighlightStep extends OnboardingStep {
  const HighlightStep({
    required super.title,
    required super.body,
    required this.target,
    required this.overlay,
    this.multiPanelAlignment = MultiPanelContentAlignment.center,
  });

  final HighlightTarget target;

  /// Story-arc theme color used to tint the dimmed overlay around the
  /// highlighted area. Resolved at render time via [ColourSchemeData].
  final ThemeColor overlay;

  /// Where to place the step's text block within the available area beside
  /// the highlighted panel. Only applies in multi-panel mode; single-panel
  /// uses the horizontal split layout.
  final MultiPanelContentAlignment multiPanelAlignment;
}

/// Multi-panel content placement for a [HighlightStep]. The text block is
/// drawn beside the highlighted panel; this controls *where* beside it.
enum MultiPanelContentAlignment {
  /// Vertically centered on the far side of the cutout. (Default.)
  center,

  /// Top of the area on the far side of the cutout — used when the relevant
  /// content sits at the top of the highlighted panel (e.g. agenda above
  /// priorities in the left panel).
  top,

  /// Bottom of the area on the far side of the cutout — used when the
  /// relevant content sits at the bottom of the highlighted panel (e.g.
  /// priorities below agenda in the left panel).
  bottom,

  /// Vertically centered, but pushed toward the cutout instead of the far
  /// edge — used when the step talks about the highlighted panel and the
  /// text should visually anchor to it.
  nearCutout,
}

/// What to highlight during a highlight step.
sealed class HighlightTarget {
  const HighlightTarget();
}

/// Highlight a panel (desktop) or bottom nav tab (mobile).
enum PanelTarget implements HighlightTarget {
  /// Desktop: left panel. Mobile: priorities tab (index 0).
  priorities,

  /// Desktop: middle panel. Mobile: agenda tab (index 1).
  agenda,

  /// Desktop: middle panel. Mobile: feed tab (index 2).
  feed,

  /// Desktop: right panel. Mobile: new tab (index 3).
  newThread,
}

/// Highlight a specific thread (e.g. an onboarding thread created by a twist).
class ThreadTarget extends HighlightTarget {
  const ThreadTarget(this.threadId);

  final ThreadId threadId;
}

/// Highlight a thread looked up by title within a priority. Used for the
/// onboarding flow's seeded "Using Plot" content where the per-user thread
/// id isn't known at compile time. The overlay resolves the thread at step
/// activation, navigates the right panel to it, and highlights the same
/// area that [ThreadTarget] would.
class NamedThreadTarget extends HighlightTarget {
  const NamedThreadTarget({
    required this.priorityTitle,
    required this.threadTitle,
  });

  final String priorityTitle;
  final String threadTitle;
}

/// Placeholder onboarding step definitions.
///
/// The actual content will be designed separately — these demonstrate
/// the framework with representative steps.
class OnboardingSteps {
  OnboardingSteps._();

  // Step backgrounds walk the story-arc theme palette so the flow visually
  // mirrors its narrative shape: open and close on Catalyst (teal brand),
  // with the in-between beats picking up Call to Adventure, Rising Action,
  // Momentum, Turning Point, Breakthrough, and Climax along the way.
  static List<OnboardingStep> get all => [
    const FullScreenStep(
      title: 'Your best work every day',
      body:
          "Every conversation in its place.\nThe best of your day stays yours to make progress on what matters.",
      background: ThemeColor(0), // Catalyst — opener
    ),
    const FullScreenStep(
      title: 'What fills your days?',
      body:
          "Start with the roles you play. You'll add priorities under each one.",
      background: ThemeColor(1), // Call to Adventure
      contentMaxWidth: 540,
      contentBuilder: _buildRoles,
      onBeforeNext: _commitRoles,
    ),
    FullScreenStep(
      title: 'Connect your calendar',
      body: 'Plot builds your day around your schedule.',
      background: const ThemeColor(2), // Rising Action
      contentBuilder: (context) => const OnboardingCalendars(),
    ),
    FullScreenStep(
      title: 'Connect everything else',
      body:
          'Email, chat, comments, issues — bring the conversations from your other tools into Plot so you have everything you need when you choose a focus.',
      background: const ThemeColor(3), // Momentum
      contentMaxWidth: 640,
      contentBuilder: (context) => const OnboardingTools(),
    ),
    const HighlightStep(
      title: 'Your priorities',
      body:
          "Priorities capture what matters to you. You'll add projects and goals to your roles. Then you can zoom in on any priority to filter and focus, or zoom out to see everything.",
      target: PanelTarget.priorities,
      overlay: ThemeColor(4), // Turning Point
      // In multi-panel the left panel stacks agenda on top of priorities, so
      // anchor this step's text to the bottom — visually next to the
      // priorities list it describes.
      multiPanelAlignment: MultiPanelContentAlignment.bottom,
    ),
    const HighlightStep(
      title: 'Your agenda',
      body:
          "Choose where to invest your focus each day. Plot fills in your scheduled events and the priorities you're actively working on, then groups everything by day so you can shape your best day.",
      target: PanelTarget.agenda,
      overlay: ThemeColor(5), // Breakthrough
      // Multi-panel: agenda sits at the top of the left panel, so anchor the
      // text to the top. Single-panel: the overlay routes to /agenda and the
      // mobile split layout handles placement.
      multiPanelAlignment: MultiPanelContentAlignment.top,
    ),
    const HighlightStep(
      title: 'Your activity feed',
      body:
          "What's active (new updates at the top), what's scheduled, and "
          "what's done — all in one feed. Catch up across every connected "
          "app without losing your place.",
      target: PanelTarget.feed,
      overlay: ThemeColor(6), // Climax
    ),
    const HighlightStep(
      title: 'Everything is a thread',
      body:
          'Anything you work on with other people — a message, a doc, an event, an issue — is a thread with notes for context, decisions, and next steps. '
          'Threads are shared automatically with everyone on the underlying item, '
          'and many connectors sync notes both ways (a note on a Linear thread posts a comment back to Linear).',
      target: NamedThreadTarget(
        priorityTitle: 'Using Plot',
        threadTitle: 'Everything in its place',
      ),
      overlay: ThemeColor(2), // Rising Action — back into the arc
      // The cutout is the right panel; pull the text block toward it so the
      // copy reads as belonging to the thread that's highlighted.
      multiPanelAlignment: MultiPanelContentAlignment.nearCutout,
    ),
    FullScreenStep(
      title: 'Carry on',
      body:
          "You're set up with your initial priorities and connections. Start simple — focus on one or two areas you most want to invest in."
          "\n\n"
          "Questions or stuck on something? Reply on the welcome thread in Using Plot — we read every one.",
      background: const ThemeColor(0), // Catalyst — bookend the opener
      contentBuilder: _buildClosingQuote,
    ),
  ];
}

Widget _buildRoles(BuildContext context) => const OnboardingRoles();

Widget _buildClosingQuote(BuildContext context) => const Padding(
  padding: EdgeInsets.only(top: 8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '“How we spend our days is, of course, how we spend our lives.”',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xD9FFFFFF),
          fontSize: 16,
          fontWeight: FontWeight.w400,
          fontStyle: FontStyle.italic,
          decoration: TextDecoration.none,
          height: 1.5,
        ),
      ),
      SizedBox(height: 8),
      Text(
        '— Annie Dillard',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xB3FFFFFF),
          fontSize: 14,
          fontWeight: FontWeight.w400,
          decoration: TextDecoration.none,
          height: 1.5,
        ),
      ),
    ],
  ),
);

Future<void> _commitRoles(BuildContext context) async {
  await context.read<OnboardingBloc>().commitRoles();
}
