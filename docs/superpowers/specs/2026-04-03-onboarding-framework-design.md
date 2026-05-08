# Onboarding Framework Design

## Context

Plot has no onboarding experience. New users land directly in the app with no guidance on how priorities, threads, tabs, and panels work. This spec defines a framework for onboarding that:

1. Tracks per-user whether onboarding has been shown (synced across devices).
2. Shows full-screen intro pages with solid colored backgrounds.
3. Transitions to highlight-based steps that dim/blur the screen and cut out the area being introduced, with content placed directly on the overlay.
4. Works responsively on both desktop (panel-based) and mobile (tab-based).

The actual onboarding *content* (copy, number of steps, which panels to highlight) will be designed separately. This spec covers the framework and widgets only — with placeholder content to demonstrate the system.

## Architecture Overview

### State: `OnboardingBloc` (Cubit)

A new Cubit at `lib/state/onboarding.dart` manages:

- `status`: `loading | active | completed`
- `currentStep`: index into the step list (0-based, spanning both phases)
- `steps`: the full list of `OnboardingStep` definitions

On startup, it reads `user_settings.onboarding_completed` (via the Drift `UserSettingsEntity`). If `false`/`null`, it activates. When the user finishes or dismisses, it writes `true` to `user_settings` and emits `completed`.

```dart
class OnboardingBloc extends Cubit<OnboardingState> {
  OnboardingBloc() : super(const OnboardingState.loading()) {
    _init();
  }

  Future<void> _init() async {
    final settings = await UserSettingsEntity.get();
    if (settings?.onboardingCompleted == true) {
      emit(const OnboardingState.completed());
    } else {
      emit(OnboardingState.active(
        currentStep: 0,
        steps: OnboardingSteps.all,
      ));
    }
  }

  void next() { /* advance currentStep or complete */ }
  void dismiss() { /* mark completed, persist */ }
}
```

### Step Definitions

Steps are pure data objects. Two types:

```dart
sealed class OnboardingStep {
  final String title;
  final String body;
}

/// Full-screen page with solid colored background
class FullScreenStep extends OnboardingStep {
  final Color backgroundColor;
  // Optional: icon or illustration widget builder
  final Widget Function()? illustrationBuilder;
}

/// Highlight step that dims everything except a target area
class HighlightStep extends OnboardingStep {
  final HighlightTarget target;
  final Color overlayColor; // tint color for the overlay
}
```

`HighlightTarget` for the initial implementation is an enum of logical areas. The overlay maps each to a panel (desktop) or bottom nav tab (mobile) using `LayoutBloc`:

```dart
sealed class HighlightTarget {}

/// Highlight a panel/tab by logical area
enum PanelTarget implements HighlightTarget {
  priorities, // Desktop: left panel. Mobile: priorities tab (index 0)
  agenda,     // Desktop: middle panel. Mobile: agenda tab (index 1)
  feed,       // Desktop: middle panel. Mobile: feed tab (index 2)
  newThread,  // Desktop: right panel. Mobile: new tab (index 3)
}

/// Highlight a specific thread (e.g. an onboarding thread created by a twist)
class ThreadTarget implements HighlightTarget {
  final ThreadId threadId;
  const ThreadTarget(this.threadId);
}
```

**`PanelTarget`**: The overlay reads `LayoutBloc.state.multiPanel` to decide rendering mode. On desktop, it computes the cutout rect from panel widths. On mobile, it splits the screen and switches the bottom nav to the target's tab index.

**`ThreadTarget`**: The overlay navigates to the specified thread before rendering the highlight. On desktop, the right panel shows the thread and the cutout reveals the right panel. On mobile, the thread page is pushed and shown in the top half. The step's content (on the overlay) explains what the thread is for.

### Widget: `OnboardingOverlay`

Placed inside `AppShell`, wrapping the `AutoRouter` output. It's a `Stack` that conditionally renders the overlay above the app content.

```
AppShell
  FToaster
    ModalProvider
      GlobalShortcuts
        OnboardingOverlay        <-- NEW: wraps the router output
          AutoRouter(...)
```

The overlay listens to `OnboardingBloc` and renders based on the current step type:

#### Full-screen steps

- `AnimatedContainer` fills the entire screen with the step's `backgroundColor`.
- Content (title, body, optional illustration) is centered.
- Progress dots + Next button pinned at the bottom center.
- X dismiss button in the upper-right corner.
- Animated color transition between full-screen steps.

#### Highlight steps — Desktop (multiPanel)

- The app renders normally underneath.
- A `BackdropFilter` + colored `Container` covers the full screen with blur + tint.
- A `ClipPath` (using a custom clipper) cuts out the target panel's rect. The clipper computes the rect from `LayoutBloc` state and panel width preferences.
- Title, body text, progress dots, and Next button are positioned on the overlay area (not in the cutout). Placement depends on which panel is highlighted — content goes in the largest available overlay region.
- X dismiss in upper-right.

#### Highlight steps — Mobile (single panel)

- The screen is split horizontally: top half shows the app (highlighted tab), bottom half is the colored overlay.
- The bloc navigates to the correct bottom nav tab so the relevant content is visible in the top half.
- Bottom half layout:
  - X dismiss at top-right of the bottom half.
  - Scrollable content area (title + body) with flex-1.
  - Progress dots + Next button pinned at the very bottom.
- The bottom nav bar is visible in the top half (part of the highlighted area) so the user can see which tab is active.

### Data: `user_settings` changes

Add `onboarding_completed boolean` column to:

1. **Remote DB**: `libs/db/schema/50-tables/99-user-settings.sql`
2. **Local DB (Drift)**: `apps/plot/lib/store/user_settings.dart` — add column + migration
3. **SettingsBloc**: Add `onboardingCompleted` to state, but the `OnboardingBloc` reads it directly rather than going through `SettingsBloc`.

### Integration Point

`OnboardingOverlay` is added in `AppShell.build()`. The `OnboardingBloc` is provided at the `App` level (alongside `ThemeBloc`, `LocalPreferencesBloc`, `SettingsBloc`).

The `OnboardingBloc` is not created eagerly — it is created by `RootProviderState` only after `UserReady` is emitted (similar to how `NowBloc.start()` is called). This ensures the Drift database is open and `UserSettingsEntity` is available before the bloc reads from it. The `OnboardingOverlay` uses `BlocProvider.value` to access it, and renders nothing when the bloc is absent (pre-auth).

## Responsive Behavior

| Aspect | Desktop (multiPanel) | Mobile (single panel) |
|--------|---------------------|----------------------|
| Full-screen steps | Identical — fills entire window | Identical — fills entire screen |
| Highlight layout | Overlay covers all, cutout reveals panel | Top half = highlighted tab, bottom half = overlay |
| Cutout shape | Panel rect from LayoutBloc | No cutout — simple horizontal split |
| Content placement | On overlay, positioned opposite the cutout | Bottom half, scrollable |
| Bottom nav | Not shown (desktop has no bottom nav) | Visible in top half with active tab highlighted |
| Tab navigation | N/A | Bloc switches bottom nav to correct tab |
| X dismiss | Upper-right of screen | Upper-right of bottom overlay area |

## Progress Indicator

A single continuous progress indicator spans all steps (full-screen + highlight). Rendered as pill-shaped dots:

- Current step: wider pill, white/opaque
- Other steps: small circle, semi-transparent white
- Positioned beside the Next button

## Animations

- Full-screen step transitions: animated background color change (via `AnimatedContainer` or `TweenAnimationBuilder`).
- Full-screen to highlight transition: background fades to transparent, then overlay + blur fades in.
- Between highlight steps: crossfade content, animate cutout position if target changes.
- Dismissal: overlay fades out.

## Files to Create/Modify

### New files
- `lib/state/onboarding.dart` + `lib/state/onboarding_state.dart` — Bloc + state
- `lib/widget/onboarding/onboarding_overlay.dart` — main overlay widget
- `lib/widget/onboarding/onboarding_full_screen.dart` — full-screen step renderer
- `lib/widget/onboarding/onboarding_highlight.dart` — highlight step renderer (desktop + mobile variants)
- `lib/widget/onboarding/onboarding_progress.dart` — progress dots + Next button
- `lib/widget/onboarding/onboarding_steps.dart` — step definitions (placeholder content)

### Modified files
- `libs/db/schema/50-tables/99-user-settings.sql` — add `onboarding_completed` column
- `apps/plot/lib/store/user_settings.dart` — add Drift column + entity methods
- `apps/plot/lib/store/store.dart` — bump schema version, add migration
- `apps/plot/lib/app.dart` — provide `OnboardingBloc`
- `apps/plot/lib/widget/app_shell.dart` — wrap router output with `OnboardingOverlay`

### Existing code to reuse
- `LayoutBloc` (`lib/state/layout.dart`) — determines desktop vs mobile, panel widths
- `UserSettingsEntity` (`lib/store/user_settings.dart`) — read/write onboarding flag
- `ColourSchemeData` / `ThemeColor` (`lib/style/colors.dart`, `lib/util/theme_color.dart`) — derive full-screen background colors from theme
- `BottomNavigationScope` (`lib/widget/bottom_navigation_provider.dart`) — understand mobile tab state

## Verification

1. **New user flow**: Sign up a new account. Onboarding should appear immediately after first load. Walk through all steps with Next. Verify `onboarding_completed` is set in local DB and synced to remote.
2. **Dismiss flow**: Start onboarding, tap X on step 2. Verify onboarding disappears and flag is persisted. Reload app — onboarding should not reappear.
3. **Returning user**: Existing user with `onboarding_completed = true` should never see onboarding.
4. **Desktop layout**: Verify full-screen steps fill the window. Verify highlight steps show correct panel cutouts with blur + tint. Verify content is readable on the overlay.
5. **Mobile layout**: Verify full-screen steps fill the screen. Verify highlight steps split the screen with highlighted tab on top and content on bottom. Verify correct bottom nav tab is active. Verify content scrolls if long.
6. **Responsive transition**: Resize window from desktop to mobile width while onboarding is active. Verify layout adapts correctly.
7. **Multi-device sync**: Complete onboarding on one device. Sign in on another. Verify onboarding does not appear.
8. **Lint**: `flutter analyze` passes.
