import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart' show Role, ThreadId;
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/onboarding/onboarding_role.dart';
import 'package:plot/widget/onboarding/onboarding_tools.dart';

/// A single step in the onboarding flow.
sealed class OnboardingStep {
  const OnboardingStep({
    required this.title,
    required this.body,
    this.shouldSkip,
    this.dismissible = true,
  });

  final String title;
  final String body;

  /// When provided and it returns true, the flow passes over this step in both
  /// directions — `OnboardingBloc.next()`/`previous()` walk past it. Used by the
  /// role follow-up step, which only applies to options that need a typed name
  /// (Work/Project/Other) and is skipped for Personal/School. Null = never skip.
  final bool Function()? shouldSkip;

  /// Whether the user may close onboarding (the × button) while on this step.
  /// The welcome and role-selection steps are non-dismissible so a brand-new
  /// user can't skip onboarding before choosing a role; from "Connect your
  /// tools" onward (a role has been committed) the × returns so the user can
  /// bail out of the remaining tour. Default true.
  final bool dismissible;
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
    this.titleBuilder,
    this.canAdvance,
    this.advanceListenable,
    super.shouldSkip,
    super.dismissible,
  });

  /// When provided, overrides [title] at render time so a step can compute its
  /// heading from live state. The role follow-up step uses this to show the
  /// selected option's prompt ("What is the project?", "Where do you work?").
  /// Falls back to [title] when null.
  final String Function()? titleBuilder;

  /// When provided and it returns false, the step's Next button is disabled and
  /// the flow refuses to advance. The role follow-up step uses this to require a
  /// non-empty name. Null = always allowed to advance.
  final bool Function()? canAdvance;

  /// When provided, the pager rebuilds whenever this fires so [canAdvance] is
  /// re-evaluated live (e.g. as the user types into the follow-up field). Paired
  /// with [canAdvance]; ignored when that is null.
  final Listenable? advanceListenable;

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
  static List<OnboardingStep> get all {
    // One holder per onboarding session, shared between the role step's
    // contentBuilder (which writes the user's selection) and its onBeforeNext
    // (which reads it to name the default role). Safe because this getter is
    // built once in OnboardingBloc.start() for the life of the flow.
    final roleSelection = OnboardingRoleSelection();
    return [
      const FullScreenStep(
        title: "All your work,\nready for action",
        body:
            "Your team chat, email, meeting notes, and app threads, organized and prioritized.",
        background: ThemeColor(0),
        // No × until a role is chosen — keep the user in the flow.
        dismissible: false,
      ),
      FullScreenStep(
        title: 'Where do you want to use Plot first?',
        body:
            'Plot organizes your work by role. Pick one to start with. You '
            'can add more later.',
        background: const ThemeColor(2),
        contentBuilder: (context) =>
            OnboardingRoleContent(selection: roleSelection),
        // Personal/School need no name, so commit here — their follow-up step
        // is skipped. Prompted options (Work/Project/Other) defer the commit to
        // the follow-up step below, where the user types the name.
        onBeforeNext: (context) => _commitRoleIfUnprompted(roleSelection),
        // The role choice is mandatory: no × on the picker.
        dismissible: false,
      ),
      // Follow-up step: collects the typed name for options that need one
      // (Work/Project/Other). Its heading is the selected option's question
      // and the field is autofocused. Skipped — in both directions — for
      // Personal/School via [shouldSkip], so the pager's back chevron returns
      // straight to the picker.
      FullScreenStep(
        title: 'Name your role',
        titleBuilder: () => roleSelection.option.prompt ?? 'Name your role',
        body: '',
        background: const ThemeColor(2),
        contentBuilder: (context) =>
            OnboardingRolePromptContent(selection: roleSelection),
        onBeforeNext: (context) => _commitRole(roleSelection),
        shouldSkip: () => roleSelection.option.prompt == null,
        // The name is required: Next stays disabled until the field has
        // non-whitespace content, and the pager re-checks as the user types.
        canAdvance: () => roleSelection.text.trim().isNotEmpty,
        advanceListenable: roleSelection.textListenable,
        // Still naming the role — no × until it's committed.
        dismissible: false,
      ),
      FullScreenStep(
        title: 'Connect your tools',
        body:
            "Plot brings all your conversations together. Calendars show your agenda and group meeting notes. Apps add your tasks, comments, and more.",
        background: const ThemeColor(1),
        contentMaxWidth: 640,
        contentBuilder: (context) => const OnboardingTools(),
      ),
      const HighlightStep(
        title: 'Built for action',
        body:
            "New and unread items arrive at the bottom of Active, below your committed to-dos. Read them and they'll move to Done.\n"
            'Mark threads "To do" to keep them in Active until done.\n'
            "Prioritize threads by dragging them, or schedule them to do later.",
        target: PanelTarget.feed,
        overlay: ThemeColor(3),
      ),
      const HighlightStep(
        title: 'Make something happen',
        body:
            'Start with the people you want to reach, then pick how to send your message.\n'
            'Or create a post or app item using a channel.\n'
            'Plot threads also hold private notes and tasks alongside the rest of your work.',
        target: PanelTarget.newThread,
        overlay: ThemeColor(2),
        // The cutout is the right panel (the new-thread compose page); pull the
        // text block toward it so the copy reads as belonging to it.
        multiPanelAlignment: MultiPanelContentAlignment.nearCutout,
      ),
      const HighlightStep(
        title: 'Focus on what matters',
        body:
            "Everything in one place can be a bit much. Create a focus to gather everything related to a role, activity, or project.\n"
            "Low-urgency messages — newsletters, promotions, receipts — collect in your FYI focus, so your Inbox stays focused on what needs your attention. Skim FYI when you have time; moving threads in and out teaches Plot where to put similar threads.",
        target: PanelTarget.priorities,
        overlay: ThemeColor(4),
        // In multi-panel the left panel stacks agenda on top of the focuses, so
        // anchor this step's text to the bottom — visually next to the focuses
        // list it describes.
        multiPanelAlignment: MultiPanelContentAlignment.top,
        // Sample-focus chips let the user spin up their first focuses right
        // here, beside the highlighted focuses panel they'll appear in.
      ),
      FullScreenStep(
        title: "You're all set",
        body:
            "We're eager to see what you'll do! Share your hopes, wins, and feedback with us any time.",
        background: const ThemeColor(0),
        contentBuilder: _buildClosingQuote,
      ),
    ];
  }

  /// Names the user's existing default role from the onboarding answer. Runs as
  /// the role step's `onBeforeNext`, so throwing surfaces the generic onboarding
  /// error toast and blocks advancing (acceptable for a transient failure).
  ///
  /// Activation seeds every user a default 'Personal' role (theme 0) whose Inbox
  /// is the root. Onboarding must **rename that seed** to the user's choice —
  /// never create a second role beside it, which would leave the user with both
  /// 'Personal' and their selection. Renaming keeps theme 0 and the single-role
  /// (flat sidebar) shape; if the user picked Personal the rename is a no-op.
  ///
  /// The seed is normally synced by critical sync before onboarding starts, but
  /// if `Role.all()` is empty (cold sync lag) we pull once so we still rename
  /// the seed rather than duplicate it. Only when no role exists even after a
  /// pull do we create one — with the chosen name, never 'Personal'.
  static Future<void> _commitRole(OnboardingRoleSelection sel) async {
    final name = sel.option.roleName(sel.text);
    var roles = await Role.all();
    if (roles.isEmpty) {
      try {
        await Role.pull();
        roles = await Role.all();
      } catch (_) {
        // Offline / transient sync failure — fall through to creating the role
        // locally. It pushes when connectivity returns; never blocks onboarding.
      }
    }
    if (roles.isNotEmpty) {
      final seed = roles.first;
      // Skip a redundant write when the seed already carries the chosen name
      // (e.g. the user picked Personal, or navigated back and forth).
      if (seed.name != name) await seed.copyWith(name: name).save();
    } else {
      await Role.create(name: name, color: const ThemeColor(0)).save();
    }
  }

  /// Commits the role from the picker step only for options that need no
  /// follow-up (Personal/School). Prompted options (Work/Project/Other) defer
  /// to the follow-up step's `onBeforeNext` so the name the user types there is
  /// included. `_commitRole` is an idempotent rename, so the single commit on
  /// whichever step is last in the role sub-flow is the one that sticks.
  static Future<void> _commitRoleIfUnprompted(
    OnboardingRoleSelection sel,
  ) async {
    if (sel.option.prompt == null) {
      await _commitRole(sel);
    }
  }
}

Widget _buildClosingQuote(BuildContext context) => const Padding(
  padding: EdgeInsets.only(top: 8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '“Alone we can do so little; together we can do so much.”',
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
        '— Helen Keller',
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
