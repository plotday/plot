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
  });

  final HighlightTarget target;

  /// Story-arc theme color used to tint the dimmed overlay around the
  /// highlighted area. Resolved at render time via [ColourSchemeData].
  final ThemeColor overlay;
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
      title: 'Progress on priorities',
      body:
          "You choose where to invest.\nPlot surfaces your work, ready for action.",
      background: ThemeColor(0), // Catalyst — opener
    ),
    const FullScreenStep(
      title: 'What fills your days?',
      body: "Start with the roles you play. You'll add priorities under each one.",
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
          'Bring your work into Plot so when you choose a focus, you have everything you need to make progress.',
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
    ),
    const HighlightStep(
      title: 'Your agenda',
      body:
          "Add anything that needs action to your agenda, where threads are grouped by priority. Then choose where to invest by blocking out time and arranging your day.",
      target: PanelTarget.agenda,
      overlay: ThemeColor(5), // Breakthrough
    ),
    const HighlightStep(
      title: 'Your activity feed',
      body:
          "Find everything you've done recently. Catch up on new activity from "
          "others, whether they're working in Plot or in any of your connected apps.",
      target: PanelTarget.feed,
      overlay: ThemeColor(6), // Climax
    ),
    const HighlightStep(
      title: 'Everything is a thread',
      body:
          'Anything you work on — messages, documents, events — is a thread with notes, so you can capture what you need to jump back in (including tasks for you and others). '
          'Threads are shared automatically with everyone on the underlying item (e.g. event attendees), '
          'and many connectors sync notes both ways (e.g. a note on a Linear thread posts a comment back to Linear).',
      target: NamedThreadTarget(
        priorityTitle: 'Using Plot',
        threadTitle: 'Everything in its place',
      ),
      overlay: ThemeColor(2), // Rising Action — back into the arc
    ),
    FullScreenStep(
      title: 'Ready for action',
      body:
          "You're all set with your initial priorities and work. Start simple — focus on one or two areas you most want to invest in."
          "\n\n"
          "If you have questions or need help, start a thread in the Using Plot priority.",
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
