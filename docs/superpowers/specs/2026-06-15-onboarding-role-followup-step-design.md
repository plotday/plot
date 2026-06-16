# Onboarding role step: split the follow-up into its own step

**Date:** 2026-06-15
**Status:** Approved, implementing
**Area:** Flutter app — onboarding flow (`apps/plot/lib/widget/onboarding/`)

## Problem

The "Where do you want to use Plot first?" onboarding step lists five role
options and, when a name-requiring option is selected, reveals a follow-up text
field **below all five tiles**. Two problems:

1. The field sits at the bottom of a tall column and is easy to miss.
2. The whole content+pager group is vertically centered (`onboarding_overlay.dart`
   `Center` + min-height trick), so when the field appears the column grows and
   everything re-centers — a surprising jump.

## Solution

Replace the inline field with a **conditional follow-up step** that reuses the
standard onboarding chrome (heading + pager with its existing back chevron). No
custom collapse/animation; the interaction model is one the user already knows.

- The role step becomes a clean single-select list of five option tiles, each
  with a **leading icon** for visual interest. No inline field.
- Picking an option that needs a name — **Work, Project, Other** — and tapping
  Next advances to a follow-up step whose **heading is the question itself**
  ("What is the project?", "Where do you work?", "What should we call this
  role?") with a single **autofocused** text field below it.
- **Personal** and **School** need no name, so the follow-up step is **skipped**
  in both directions; Next goes straight to "Connect your tools" and Back from
  there returns to the picker.
- "Go back" is the pager's existing back chevron (auto-wired whenever
  `currentStep > 0`).

### Option list change

`RoleOption` (`onboarding_role.dart`): drop `volunteering`, add `project` in 2nd
position → `work, project, personal, school, other`.

| Option   | Icon (FontAwesome) | Prompt                          | Placeholder       | Role name           |
|----------|--------------------|---------------------------------|-------------------|---------------------|
| work     | `briefcase`        | Where do you work?              | Acme Co           | text or "Work"      |
| project  | `rocket`           | What is the project?            | Website redesign  | text or "Project"   |
| personal | `user`             | — (none)                        | —                 | "Personal"          |
| school   | `graduationCap`    | — (none)                        | —                 | "School"            |
| other    | `shapes`           | What should we call this role?  | Superhero         | text or "Other"     |

### Advance on selection

Tapping a role tile advances immediately — no separate Next tap. The picker
content is built via `contentBuilder` and has no direct handle to the step's
advance action, so `_FullScreenLayer` provides it through an
`OnboardingStepScope` InheritedWidget (wrapping the step content, keyed by
step). The tile's `onTap` calls `OnboardingStepScope.maybeOf(context)` and runs
it, which is exactly the pager Next flow (`_handleNext`: run `onBeforeNext` then
`next()`). Prompted options land on the autofocused follow-up step; unprompted
options skip straight ahead. `maybeOf` returns null when no scope is present
(isolated widget tests), so the tile falls back to plain selection. The pager
Next button stays for keyboard/fallback use.

### Required name

The follow-up name is required — you can't advance with an empty field.
`FullScreenStep` gains `canAdvance` (a `bool Function()?`) and `advanceListenable`
(a `Listenable?`). The follow-up step sets `canAdvance: () =>
roleSelection.text.trim().isNotEmpty` and `advanceListenable:
roleSelection.textListenable` (the selection's `text` is now a `ValueNotifier`).
`_FullScreenLayer` wraps the pager in a `ListenableBuilder` on
`advanceListenable`, so Next disables/enables live as the user types;
`OnboardingProgress.onNext` is nullable and renders a greyed, non-interactive
Next when null. `_handleNext` also short-circuits when `canAdvance` is false
(defense in depth, e.g. for Enter). Enter ("done") submits via the step scope,
which runs the same gated advance — a no-op while empty.

### Conditional-step mechanism

Two optional hooks added to the step model:

- `bool Function()? shouldSkip` on `OnboardingStep` (base). `OnboardingBloc.next()`
  and `previous()` walk over any step whose predicate returns true, so skipping
  works in both directions. Default null → never skip (all existing steps
  unaffected).
- `String Function()? titleBuilder` on `FullScreenStep`. The renderer uses
  `titleBuilder?.call() ?? title`, letting the follow-up step's heading be the
  selected option's prompt. The renderer also skips rendering the body Text when
  it is empty.

The follow-up step's `shouldSkip` is `() => roleSelection.option.prompt == null`
(true for Personal/School).

### Commit timing

`_commitRole` reads `roleSelection.option` + `.text`. The typed name now lives on
the follow-up step, so commit must run after it:

- Picker step `onBeforeNext`: commit **only when the option has no prompt**
  (Personal/School commit here; prompted options defer).
- Follow-up step `onBeforeNext`: `_commitRole` (the only path prompted options
  take).

Exactly one commit either way; `_commitRole` is an idempotent rename so
last-write-wins across back-and-forth navigation. The shared `OnboardingRoleSelection`
holder already persists across steps for the life of the flow.

### Field widget

The inline `_RolePromptField` content moves to a small stateful content widget
used by the follow-up step. It owns a `TextEditingController` initialized from
`roleSelection.text` (preserved if the user returns to the same option; cleared
by the picker's `_select` when the option changes) and writes changes back to
`roleSelection.text`. No in-card label — the step heading carries the question.

**Focus.** The onboarding overlay renders in a plain `Stack` over the
`AutoRouter`, with no `FocusScope` of its own, so the follow-up field shares one
focus scope with whatever route is behind it. In multi-panel the new-thread
composer is mounted there and grabs focus at app start (via `AutofocusReclaim`).
`EditableText`'s passive `autofocus` is a no-op once the shared scope has an
owner (`FocusScopeNode.autofocus` does nothing when the scope already has a
focused child), so the field never focused in the live app even though the
isolated widget test passed. Fix: the content claims focus **actively** with an
explicit post-frame `focusNode.requestFocus()` (unconditional — it takes focus
from the composer), and wraps the field in the codebase's `AutofocusReclaim` to
survive the documented macOS/navigator focus-clearing races. `AutofocusReclaim`
re-grabs only when focus is ownerless (root scope / none), so it never yanks
focus from a deliberate move to the pager.

## Files

- `onboarding_role.dart` — options (drop volunteering, add project), `icon`
  getter, leading icon on tiles, picker reduced to the list, new autofocused
  follow-up content widget.
- `onboarding_steps.dart` — insert follow-up step after the picker, split commit
  timing, `shouldSkip` + `titleBuilder` wiring.
- `onboarding_full_screen.dart` — `titleBuilder ?? title`, skip empty body.
- `onboarding.dart` — skip logic in `next()`/`previous()`.
- `onboarding_step_scope.dart` (new) — `OnboardingStepScope` InheritedWidget.
- `onboarding_overlay.dart` — wrap step content in `OnboardingStepScope`.
- `apps/plot/scripts/cache-bust-fonts.sh` — bump `FONT_CACHE_VERSION` (new FA
  icons added; web tree-shakes icon fonts).
- `onboarding_progress.dart` — unchanged.

## Tradeoff (accepted)

The follow-up step is always present in the list (8 dots total). For
Personal/School users the active progress pill slides **past** one dot rather
than landing on it. Keeping the dot count fixed is calmer than letting the total
flicker as the selection changes between prompted/unprompted options.

## Testing

- Unit: extend onboarding bloc coverage — `next()`/`previous()` skip a step whose
  `shouldSkip()` is true, in both directions; non-skipped steps unaffected.
- `flutter analyze` clean.
- run-app: verify picker shows icons; Work/Project/Other → follow-up heading is
  the question + autofocused field; Personal/School → straight to Connect tools;
  back chevron returns to picker; role name committed correctly.
