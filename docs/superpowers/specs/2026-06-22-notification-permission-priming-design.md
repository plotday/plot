# Notification permission: priming + re-enable

**Date:** 2026-06-22
**Status:** Approved design — ready for implementation plan
**Scope:** Flutter app (`apps/plot/`). No schema, no server changes.

## Problem

On a freshly installed **Android** app there is no prompt to enable notifications,
so push never works for new Android users unless they discover the Settings tile.

### Root cause (confirmed)

The prompt is requested after sign-in by
`NotificationService._requestPermissionAndRegister()`
(`apps/plot/lib/notifications/notification_service.dart:356`):

```dart
final currentSettings = await messaging.getNotificationSettings();
if (currentSettings.authorizationStatus == AuthorizationStatus.denied) {
  if (Platform.isAndroid) {
    _permissionDenied = true;   // bails out — never prompts
    return;
  }
}
if (currentSettings.authorizationStatus == AuthorizationStatus.notDetermined) {
  await messaging.requestPermission();   // the only path that actually prompts
}
```

Verified against `firebase_messaging` 16.2.1 Android source
(`FlutterFirebaseMessagingPlugin.getPermissions()`): on Android the plugin maps
`POST_NOTIFICATIONS` to **only** `authorized` (granted) or `denied` (not granted).
It **never returns `notDetermined` on Android**. So on a fresh Android 13+ install
the permission isn't granted yet → status is `denied` → the code treats it as
"user explicitly refused, don't re-ask" and returns. The `notDetermined` branch
that triggers the OS dialog is unreachable on Android. iOS is unaffected (it does
return `notDetermined`, so iOS prompts on first sign-in).

The same flawed assumption is in the Settings-tile path
(`requestPermission()`, lines 592–598): a fresh-install Android user who taps
"Enable notifications" is sent to system settings instead of getting the OS dialog.

Two related gaps:
- **No priming / explanation.** Even on iOS we fire the raw OS dialog immediately
  after sign-in with zero context, which tends to get denied.
- **No re-enable prompt.** If a previously-granted permission is later revoked
  (system auto-revoke, user toggled it off in OS settings), nothing nudges the
  user to turn it back on.

## Goals

1. A clear, benefit-explaining in-app request to enable notifications at an
   appropriate time (after onboarding completes), on iOS, Android, and macOS.
   The OS prompt fires only when the user taps **Enable**.
2. If notifications were previously enabled on this device and the OS permission
   has since been removed, prompt to re-enable — using the **same modal** for
   consistency.
3. The user can always opt out, and opting out is respected (no nagging).
4. Track opt-in/out **per device** (a user may want Android notifications but not
   desktop, or vice versa).
5. Fix the underlying Android detection bug so the OS prompt actually appears.

## Non-goals

- No new red "More" tab badge / account-menu indicator. The existing Settings
  "Enable notifications" tile remains the always-available manual path.
- No new native dependency (no `permission_handler`).
- No synced/server-side notification-opt-in state.
- No changes to the per-role notification windows / "see within" settings.
- No retroactive behavior for users who already have notifications working
  (they are reconciled silently to `optedIn`, never re-prompted).

## Design

### 1. Per-device opt-in state

A single `ProfilePreferences` string keyed by user:
`notif_prompt_state:<userId>`. `ProfilePreferences` is already profile-scoped and
stored locally per device (see `apps/plot/lib/util/profile_preferences.dart`), so
this is automatically per-device per-user — no extra plumbing for goal #4.

Enum values (serialized as strings; absent key == `unset`):

- `unset` — never resolved (fresh install / first run after this ships).
- `optedIn` — user enabled and the OS grant succeeded at least once.
- `declined` — user tapped **Not now** or denied the OS dialog.

### 2. Decision logic — `NotificationService.evaluate()`

Returns an enum describing what the UI should do, given the current OS permission
status and the stored per-device state. This is the single source of truth for the
behavior and the primary unit-tested surface.

```
enum NotificationPromptAction { none, showPriming, showReEnable }
```

| OS permission | stored state | action          | side effect                              |
|---------------|--------------|-----------------|------------------------------------------|
| granted       | any          | `none`          | register token if needed; set `optedIn`  |
| not granted   | `unset`      | `showPriming`   | —                                        |
| not granted   | `optedIn`    | `showReEnable`  | — (had it, lost it)                      |
| not granted   | `declined`   | `none`          | — (respect opt-out)                      |

Notes:
- **First run after upgrade** reconciles existing users: if the OS permission is
  already granted, state becomes `optedIn` and nothing is shown. Existing users
  who never granted (e.g. Android users hit by the bug) are `unset` → primed once.
- On Windows, notifications need no OS permission; `evaluate()` treats it as
  effectively granted (`optedIn`, action `none`) — no prompt.

### 3. The reused modal

A single `ConfirmModal` (`apps/plot/lib/widget/confirm_modal.dart`) with variant
copy. Buttons: confirm = **Enable notifications**, cancel = **Not now**.

- **Priming** (`showPriming`): title "Stay on top of what matters", message
  "Get notified when important threads need your attention — even when Plot is
  closed."
- **Re-enable** (`showReEnable`): title "Notifications are turned off", message
  "Turn them back on so Plot can alert you about important threads."

Actions:
- **Enable** → `NotificationService.enableFromUser()`:
  - Runs the corrected OS request (see §5). On success: register token, set
    `optedIn`, toast "Notifications enabled".
  - If the OS won't show a dialog because it's permanently denied (Android
    asked-before, macOS not-`notDetermined`), deep-link to system settings via the
    existing `_openSystemSettings()` path and leave state unchanged.
- **Not now** → `NotificationService.declineFromUser()` → set `declined`. Applies
  to both priming and re-enable (re-enable "Not now" = stop asking, per decision).
  The Settings tile remains available to enable later.

UI text uses sentence case per app conventions. The modal is shown through the
`Modal`/`ConfirmModal` framework (never `showDialog`/`FDialog` directly).

### 4. Trigger — `NotificationPromptCoordinator`

A small listener mounted in the app shell (alongside the onboarding overlay) that:
- Fires once per launch when **all** hold: `UserReady`; `OnboardingBloc` state is
  `OnboardingCompleted` (so it never overlaps active onboarding — for returning
  users this is the initial resolved state, so it still fires after they land);
  and `Scenes.active` is false (never prompt during screenshot scenes).
- Calls `NotificationService.evaluate()` and shows the priming or re-enable modal
  accordingly; `none` shows nothing.
- Re-evaluates on `AppLifecycleState.resumed` so a system revocation surfaces the
  re-enable modal when the user returns to the app. (Guarded so it shows at most
  once per resume and not while a prompt is already on screen.)

`NotificationService.start()` keeps registering the FCM/APNS token for
already-granted users, but **no longer auto-prompts** — the OS prompt is owned by
the modal's Enable action.

### 5. Android request fix (the bug)

In the request path (`enableFromUser`, replacing the broken auto-prompt and the
Settings-tile logic):

- **Do not** early-return on Android `denied`. Always call
  `messaging.requestPermission()` when not already authorized — the OS decides
  whether to show the dialog (shows it when askable; no-ops otherwise), so the call
  is always safe.
- Map the result:
  - granted/provisional → register token, `optedIn`, success.
  - denied: if the prior stored state was `unset` (first ask) → treat as a normal
    decline (`declined`, informative toast). If the prior state was `optedIn`/we
    had asked before → treat as permanently denied → deep-link to system settings.
- iOS keeps its existing APNS-token wait/registration flow unchanged.
- macOS: `requestMacOSPermission()` when `notDetermined`, else deep-link to System
  Settings (existing behavior), feeding the same `optedIn`/`declined` transitions.

### 6. Settings tile

`EnableNotifications` (`apps/plot/lib/command/settings.dart:706`) — already shown
when `NotificationService.isSupported && !isTokenRegistered` — routes through the
same `enableFromUser()` and shows an accurate subtitle (e.g. "Off — tap to turn
on" / "Permission denied — open settings"). No new badge.

## Components & boundaries

- `NotificationService` (existing singleton): owns OS-permission mechanics, token
  registration, per-device state persistence, and exposes `evaluate()`,
  `enableFromUser()`, `declineFromUser()`. No `BuildContext`.
- `NotificationPromptCoordinator` (new): the UI-side trigger; owns *when* to show
  the modal and shows it. Depends on `NotificationService` + `OnboardingBloc`
  state + app lifecycle.
- `ConfirmModal` (existing): the *what to show*. Variant copy passed in by the
  coordinator.
- `EnableNotifications` command (existing): manual entry point, delegates to the
  service.

This keeps the testable decision logic (`evaluate()` + request-result mapping) in
the service, free of UI, and the timing/presentation in the coordinator.

## Testing

TDD, pure where possible:
- `evaluate()` truth table (all OS-status × stored-state combinations, per
  platform branch). This directly encodes the regression that caused the bug.
- Android request-result mapping: `denied`+`unset` → prompt attempt → decline;
  `denied`+asked-before → settings deep-link; granted → optedIn.
- State persistence round-trips through `ProfilePreferences`.
- Coordinator gating logic (only fires on `OnboardingCompleted`, not during
  `Scenes`, once per launch) — pure where extractable.
- `flutter analyze` clean.
- Manual verification via the `run-app` skill: fresh-state priming modal appears;
  Enable triggers the OS prompt; Not now suppresses; revoking permission surfaces
  the re-enable modal on resume.

## Files

Changed:
- `apps/plot/lib/notifications/notification_service.dart` — fix Android request;
  add state model + `evaluate()`/`enableFromUser()`/`declineFromUser()`; stop
  auto-prompting in `start()`.
- `apps/plot/lib/command/settings.dart` — `EnableNotifications` delegates to the
  service; accurate subtitle.
- App shell (where `OnboardingOverlay` is mounted, e.g.
  `apps/plot/lib/widget/app_shell.dart`) — mount the coordinator.
- `docs/updates.md` — one user-facing bullet.

New:
- `apps/plot/lib/notifications/notification_prompt_coordinator.dart` — the trigger.
- `apps/plot/lib/notifications/notification_prompt_modal.dart` (or a helper in the
  coordinator) — builds the priming/re-enable `ConfirmModal` copy.
- Tests under `apps/plot/test/` for `evaluate()` and request mapping.

## Edge cases

- Screenshot scenes: coordinator skips while `Scenes.active`.
- Sign-out/in: state is keyed per user; a different user on the same device gets
  their own state.
- Permission granted out-of-band (user enables in OS settings): next `evaluate()`
  sees granted → registers token, sets `optedIn` — a prior `declined` is cleared.
- Returning user on a brand-new device: `unset` + not granted → primed once
  (correct — we want to ask per device).
- Windows: no OS permission; never prompts.

## Rollout

Ships with the app; no server/schema coordination. Existing users with working
notifications are reconciled to `optedIn` and never see a modal. Android users who
were silently never-prompted get the priming modal once after their next
onboarding-complete/launch.
