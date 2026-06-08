import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart' show ThreadId;
import 'package:plot/util/theme_color.dart';
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
    this.contentBuilder,
  });

  final HighlightTarget target;

  /// Story-arc theme color used to tint the dimmed overlay around the
  /// highlighted area. Resolved at render time via [ColourSchemeData].
  final ThemeColor overlay;

  /// Where to place the step's text block within the available area beside
  /// the highlighted panel. Only applies in multi-panel mode; single-panel
  /// uses the horizontal split layout.
  final MultiPanelContentAlignment multiPanelAlignment;

  /// Optional interactive content shown below the body text, beside the
  /// highlighted panel — e.g. the sample-focus chips on the "Where do you
  /// focus?" step. The content column scrolls if it outgrows the available
  /// height so a tall builder never overflows the overlay.
  final Widget Function(BuildContext context)? contentBuilder;
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

/// Highlight an onboarding thread looked up by title within the user's Inbox
/// (root). Used for the seeded onboarding content where the per-user thread id
/// isn't known at compile time. The overlay resolves the thread at step
/// activation, navigates the right panel to it, and highlights the same area
/// that [ThreadTarget] would.
class NamedThreadTarget extends HighlightTarget {
  const NamedThreadTarget({required this.threadTitle});

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
      title: "Your best work\nevery day",
      body:
          "Plot is your collaboration hub. All your messages, meetings, and apps — organized and prioritized.",
      background: ThemeColor(0), // Catalyst — opener
    ),
    FullScreenStep(
      title: 'Connect your tools',
      body:
          'Add the message channels, calendars, and apps that hold your work.',
      background: const ThemeColor(1),
      contentMaxWidth: 640,
      contentBuilder: (context) => const OnboardingTools(),
    ),
    const HighlightStep(
      title: 'Everything is a thread',
      body:
          "Threads you create in Plot alongside everything from your connections lands in a focus (or your Inbox). "
          "Updates appear at the top, followed by threads you've marked Active (something that needs your attention or action). "
          "You can \"snooze\" threads to clear them from today and make sure you get back to them later.",
      target: PanelTarget.feed,
      overlay: ThemeColor(6), // Climax
    ),
    const HighlightStep(
      title: 'Everything is a thread',
      body:
          'Anything you work on with other people — a message, a doc, an event, an issue — is a thread with notes for context, decisions, and next steps. '
          'Threads are synced both ways so you see new messages in Plot and messages you add in Plot appear in your connection.',
      target: NamedThreadTarget(threadTitle: 'Everything in its place'),
      overlay: ThemeColor(2), // Rising Action — back into the arc
      // The cutout is the right panel; pull the text block toward it so the
      // copy reads as belonging to the thread that's highlighted.
      multiPanelAlignment: MultiPanelContentAlignment.nearCutout,
    ),
    const HighlightStep(
      title: 'Choose your focus',
      body:
          "In Plot, a focus is a separate inbox with everything related to a role, activity, or project. Focuses are great for concentrating on your top priorities. They're also helpful for collecting low-urgency work to keep it from interrupting your day, allowing you to tackle it efficiently when you have time.",
      target: PanelTarget.priorities,
      overlay: ThemeColor(4), // Turning Point
      // In multi-panel the left panel stacks agenda on top of the focuses, so
      // anchor this step's text to the bottom — visually next to the focuses
      // list it describes.
      multiPanelAlignment: MultiPanelContentAlignment.top,
      // Sample-focus chips let the user spin up their first focuses right
      // here, beside the highlighted focuses panel they'll appear in.
      contentBuilder: _buildRoles,
    ),
    const HighlightStep(
      title: 'Your day',
      body:
          "See your day at glance. Easily add focus blocks to ensure you make progress on what matter most.",
      target: PanelTarget.agenda,
      overlay: ThemeColor(5), // Breakthrough
      // Multi-panel: the agenda occupies the bottom half of the left panel
      // (leftBottom), starting around the vertical midpoint. Center the text
      // so it sits beside where the agenda begins rather than hugging the
      // bottom edge. Single-panel: the overlay routes to /agenda and the
      // mobile split layout handles placement.
      multiPanelAlignment: MultiPanelContentAlignment.center,
    ),
    FullScreenStep(
      title: "You're all set!",
      body:
          "We've put added a few threads"
          "You're set up with your initial focuses and connections. Start simple — focus on one or two areas you most want to invest in."
          "\n\n"
          "Questions or stuck on something? Reply on the welcome thread in your Inbox — we read every one.",
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
