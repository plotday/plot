# Notification Permission Priming + Re-enable — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a benefit-explaining in-app prompt to enable notifications after onboarding (and a re-enable prompt when a previously-granted permission is lost), while fixing the Android bug that suppressed the OS prompt on fresh installs.

**Architecture:** A new pure decision module (`notification_prompt.dart`) holds the testable state machine. `NotificationService` gains per-device opt-in state, an `evaluate()` read, a fixed user-driven `requestPermission()`, and stops auto-prompting on sign-in. A new `NotificationPromptCoordinator` widget — mounted in the app shell under `ModalProvider` — decides *when* to show the reused `ConfirmModal`.

**Tech Stack:** Flutter, `flutter_bloc`, `firebase_messaging` 16.2.1, `flutter_local_notifications`, `shared_preferences` (via `ProfilePreferences`). No new dependencies.

## Global Constraints

- **No new native dependency** — work within `firebase_messaging` + `ProfilePreferences`. Do NOT add `permission_handler`.
- **No schema / server changes.** Flutter app only.
- **UI imports:** only `flutter/widgets.dart` and `forui/forui.dart`; never `flutter/material.dart`.
- **Modals:** use the project `ConfirmModal` (`lib/widget/confirm_modal.dart`); never `showDialog`/`showFDialog`/`FDialog` directly.
- **UI text:** sentence case (capitalize first word + proper nouns only).
- **Error capture:** any `catch` for an *unexpected* error calls `Tracker.captureException(e, st)`. Do NOT capture expected outcomes (user denial, permission-not-granted).
- **`dart:io` `Platform.isX` is already guarded** in `NotificationService` via `kIsWeb` + `Platform` checks; keep those guards.
- Per-device opt-in pref key: `notif_prompt_state:<userId>` stored via `ProfilePreferences.instance` (profile-scoped → per device).
- Run `cd apps/plot && flutter analyze` before every commit; it must be clean.

---

### Task 1: Pure prompt-decision module

**Files:**
- Create: `apps/plot/lib/notifications/notification_prompt.dart`
- Test: `apps/plot/test/notifications/notification_prompt_test.dart`

**Interfaces:**
- Produces (consumed by Tasks 2 & 3):
  - `enum NotificationPromptState { unset, optedIn, declined }`
  - `enum NotificationPromptAction { none, showPriming, showReEnable }`
  - `enum NotificationPromptOutcome { granted, declined, openSettings }`
  - `String notificationPromptStateKey(String userId)`
  - `NotificationPromptState parseNotificationPromptState(String? raw)`
  - `String serializeNotificationPromptState(NotificationPromptState state)`
  - `NotificationPromptAction decidePromptAction({required bool osGranted, required NotificationPromptState state})`
  - `NotificationPromptOutcome mapRequestOutcome({required bool granted, required bool wasFirstAsk})`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/notifications/notification_prompt_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/notifications/notification_prompt.dart';

void main() {
  group('notificationPromptStateKey', () {
    test('is namespaced per user', () {
      expect(notificationPromptStateKey('u1'), 'notif_prompt_state:u1');
    });
  });

  group('parse/serialize round-trip', () {
    test('each state survives a round-trip', () {
      for (final s in NotificationPromptState.values) {
        expect(
          parseNotificationPromptState(serializeNotificationPromptState(s)),
          s,
        );
      }
    });

    test('null / unknown parses to unset', () {
      expect(parseNotificationPromptState(null), NotificationPromptState.unset);
      expect(
        parseNotificationPromptState('garbage'),
        NotificationPromptState.unset,
      );
    });
  });

  group('decidePromptAction', () {
    test('granted → none regardless of stored state', () {
      for (final s in NotificationPromptState.values) {
        expect(
          decidePromptAction(osGranted: true, state: s),
          NotificationPromptAction.none,
        );
      }
    });

    test('not granted + unset → showPriming', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.unset,
        ),
        NotificationPromptAction.showPriming,
      );
    });

    test('not granted + optedIn → showReEnable (had it, lost it)', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.optedIn,
        ),
        NotificationPromptAction.showReEnable,
      );
    });

    test('not granted + declined → none (respect opt-out)', () {
      expect(
        decidePromptAction(
          osGranted: false,
          state: NotificationPromptState.declined,
        ),
        NotificationPromptAction.none,
      );
    });
  });

  group('mapRequestOutcome', () {
    test('granted → granted', () {
      expect(
        mapRequestOutcome(granted: true, wasFirstAsk: true),
        NotificationPromptOutcome.granted,
      );
      expect(
        mapRequestOutcome(granted: true, wasFirstAsk: false),
        NotificationPromptOutcome.granted,
      );
    });

    test('denied on first ask → declined', () {
      expect(
        mapRequestOutcome(granted: false, wasFirstAsk: true),
        NotificationPromptOutcome.declined,
      );
    });

    test('denied after a prior ask → openSettings', () {
      expect(
        mapRequestOutcome(granted: false, wasFirstAsk: false),
        NotificationPromptOutcome.openSettings,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/notifications/notification_prompt_test.dart`
Expected: FAIL — `notification_prompt.dart` / symbols not defined.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/notifications/notification_prompt.dart`:

```dart
/// Pure decision logic for the notification opt-in prompt flow.
///
/// Kept free of platform/Firebase imports so it is trivially unit-testable.
/// [NotificationService] supplies the I/O (OS permission status, persistence)
/// and calls into these functions.

/// Per-device, per-user opt-in state. Persisted as a string via
/// `ProfilePreferences` (profile-scoped → per device).
enum NotificationPromptState {
  /// Never resolved (fresh install / first run after this ships).
  unset,

  /// User enabled and the OS grant succeeded at least once.
  optedIn,

  /// User tapped "Not now" or denied the OS dialog. Auto-prompts stop.
  declined,
}

/// What the UI should do for the current (OS-permission, stored-state) pair.
enum NotificationPromptAction { none, showPriming, showReEnable }

/// Result of mapping an OS permission-request to a user-facing outcome.
enum NotificationPromptOutcome { granted, declined, openSettings }

/// Local prefs key for [NotificationPromptState], namespaced per user.
String notificationPromptStateKey(String userId) =>
    'notif_prompt_state:$userId';

/// Parse a stored state string. Null/unknown → [NotificationPromptState.unset].
NotificationPromptState parseNotificationPromptState(String? raw) {
  switch (raw) {
    case 'optedIn':
      return NotificationPromptState.optedIn;
    case 'declined':
      return NotificationPromptState.declined;
    default:
      return NotificationPromptState.unset;
  }
}

/// Serialize a state for persistence.
String serializeNotificationPromptState(NotificationPromptState state) =>
    state.name;

/// The core decision: given whether the OS currently grants notifications and
/// the stored per-device state, decide what (if anything) to prompt.
NotificationPromptAction decidePromptAction({
  required bool osGranted,
  required NotificationPromptState state,
}) {
  if (osGranted) return NotificationPromptAction.none;
  switch (state) {
    case NotificationPromptState.unset:
      return NotificationPromptAction.showPriming;
    case NotificationPromptState.optedIn:
      return NotificationPromptAction.showReEnable;
    case NotificationPromptState.declined:
      return NotificationPromptAction.none;
  }
}

/// Map the result of an OS permission request to a user-facing outcome.
/// A denial on the very first ask is a normal decline; a denial after we have
/// asked before means the OS won't show the dialog again → send to settings.
NotificationPromptOutcome mapRequestOutcome({
  required bool granted,
  required bool wasFirstAsk,
}) {
  if (granted) return NotificationPromptOutcome.granted;
  return wasFirstAsk
      ? NotificationPromptOutcome.declined
      : NotificationPromptOutcome.openSettings;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/notifications/notification_prompt_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/notifications/notification_prompt.dart \
        apps/plot/test/notifications/notification_prompt_test.dart
git commit -m "feat(notifications): pure opt-in prompt decision module"
```

---

### Task 2: Rewire NotificationService — per-device state, evaluate, fixed request, no auto-prompt

**Files:**
- Modify: `apps/plot/lib/notifications/notification_service.dart`

**Interfaces:**
- Consumes (from Task 1): all of `notification_prompt.dart`.
- Produces (consumed by Task 3):
  - `Future<NotificationPromptAction> NotificationService.evaluate()`
  - `Future<NotificationPermissionResult> NotificationService.requestPermission()` (existing signature; now fixed + writes state)
  - `Future<void> NotificationService.declineFromUser()`
  - `void NotificationService.openSystemNotificationSettings()`

This task has no standalone unit test (the testable core lives in Task 1; the
remainder is Firebase-singleton I/O verified by `flutter analyze` here and the
run-app pass in Task 5). The deliverable is a compiling, analyzer-clean service
with the new behavior.

- [ ] **Step 1: Add the import and per-device state plumbing**

At the top of `notification_service.dart`, add to the local imports block (after line 18, `focus_label.dart`):

```dart
import 'package:plot/notifications/notification_prompt.dart';
import 'package:plot/util/profile_preferences.dart';
```

Add a `_userId` field next to `_userName` (near line 60):

```dart
  /// The current user's id, captured in [start]. Keys the per-device opt-in
  /// state pref.
  String? _userId;
```

In `start(...)` (line 132), capture the id right after `_userName = userName;` (line 141):

```dart
    _started = true;
    _userId = userId;
    _userName = userName;
```

Add private state helpers (place them just below `_requestPermissionAndRegister`'s old location, anywhere in the class body):

```dart
  /// Read the per-device opt-in state for the current user.
  NotificationPromptState _loadPromptState() {
    final userId = _userId;
    if (userId == null) return NotificationPromptState.unset;
    return parseNotificationPromptState(
      ProfilePreferences.instance.getString(
        notificationPromptStateKey(userId),
      ),
    );
  }

  /// Persist the per-device opt-in state for the current user.
  Future<void> _savePromptState(NotificationPromptState state) async {
    final userId = _userId;
    if (userId == null) return;
    await ProfilePreferences.instance.setString(
      notificationPromptStateKey(userId),
      serializeNotificationPromptState(state),
    );
  }

  /// Whether the OS currently grants notifications on this platform.
  Future<bool> _isOsGranted() async {
    if (Platform.isWindows) return true; // no OS permission needed
    if (Platform.isMacOS) {
      final settings =
          await NotificationDisplay.instance.getNotificationSettings();
      return settings?['enabled'] == 'true';
    }
    // iOS / Android
    final settings =
        await FirebaseMessaging.instance.getNotificationSettings();
    final status = settings.authorizationStatus;
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }
```

- [ ] **Step 2: Replace the auto-prompt with grant-reconcile (no prompt on start)**

Delete the entire `_requestPermissionAndRegister()` method (old lines 354–408).
Replace it with `_reconcileIfGranted()` plus a token-listener helper that reuses
the old `onTokenRefresh` body:

```dart
  /// When the OS already grants notifications, register the token (mobile) and
  /// mark the device opted-in. Never prompts — the OS prompt is user-driven via
  /// [requestPermission]. Called on start and on resume.
  Future<void> _reconcileIfGranted() async {
    if (!await _isOsGranted()) return;
    _permissionDenied = false;
    if (_isMobile) {
      await _ensureTokenListenerAndRegister();
    }
    await _savePromptState(NotificationPromptState.optedIn);
  }

  /// Subscribe to FCM token refresh (once) then fetch + register the token.
  /// On iOS the first token arrives via this stream after APNS is ready, so the
  /// subscription must exist before the initial [_getTokenAndRegister].
  Future<void> _ensureTokenListenerAndRegister() async {
    final messaging = FirebaseMessaging.instance;
    _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen((token) async {
      _currentToken = token;
      try {
        await _registerToken(token);
        _tokenRegistered = true;
        _retryCount = 0;
      } catch (e) {
        log.warning('Failed to register refreshed FCM token', e);
        _scheduleRetry();
      }
    });
    await _getTokenAndRegister();
  }
```

In `_startMobile` (line 205), replace:

```dart
    await _requestPermissionAndRegister();
```

with:

```dart
    await _reconcileIfGranted();
```

In `_startDesktop` (lines 240–246), replace the macOS permission block:

```dart
    // Check macOS notification permission on startup
    if (Platform.isMacOS) {
      final settings = await NotificationDisplay.instance.getNotificationSettings();
      final isEnabled = settings?['enabled'] == 'true';
      _permissionDenied = !isEnabled;
      log.info('macOS notification permission: enabled=$isEnabled');
    }
```

with:

```dart
    // Reconcile opt-in state from the current OS permission (no prompt).
    _permissionDenied = !await _isOsGranted();
    await _reconcileIfGranted();
```

- [ ] **Step 3: Add `evaluate()` and `declineFromUser()`**

Add these public methods (e.g. just after `_reconcileIfGranted`):

```dart
  /// Decide what (if anything) to prompt the user about notifications now.
  /// Pure read: the grant-reconcile side effects live in [_reconcileIfGranted]
  /// (start/resume), so this only reads OS status + stored state.
  Future<NotificationPromptAction> evaluate() async {
    if (!isSupported || _userId == null) {
      return NotificationPromptAction.none;
    }
    if (await _isOsGranted()) return NotificationPromptAction.none;
    return decidePromptAction(osGranted: false, state: _loadPromptState());
  }

  /// Record that the user opted out (tapped "Not now"). Stops auto-prompts on
  /// this device; the Settings tile remains available to enable later.
  Future<void> declineFromUser() async {
    _permissionDenied = true;
    await _savePromptState(NotificationPromptState.declined);
  }

  /// Open the OS notification settings for this app (macOS). No-op elsewhere;
  /// callers pair this with a toast telling the user to enable in settings.
  void openSystemNotificationSettings() {
    if (Platform.isMacOS) {
      launchUrl(
        Uri.parse('x-apple.systempreferences:com.apple.Notifications-Settings'),
      );
    }
  }
```

Add the `url_launcher` import to the third-party import block if not present
(`import 'package:url_launcher/url_launcher.dart';`). Verify whether it is
already imported before adding (the file may not currently import it).

- [ ] **Step 4: Fix `requestPermission()` (the Android bug) + write state**

Replace the body of `requestPermission()` (old lines 545–616) with the version
below. The key change: the Android branch no longer early-returns on `denied`;
it always calls `messaging.requestPermission()` (the OS decides whether to show
the dialog), and the per-device state distinguishes a first-ask decline from a
permanent denial via [mapRequestOutcome].

```dart
  /// Request notification permission as a direct result of a user action
  /// (priming/re-enable modal, or the Settings tile). Writes per-device state.
  Future<NotificationPermissionResult> requestPermission() async {
    if (!isSupported) return NotificationPermissionResult.unsupported;

    if (_isDesktop) {
      try {
        await NotificationDisplay.instance.initialize();
        if (Platform.isMacOS) {
          if (await _isOsGranted()) {
            _permissionDenied = false;
            await _savePromptState(NotificationPromptState.optedIn);
            return NotificationPermissionResult.granted;
          }
          // Only works while status is notDetermined; otherwise macOS won't
          // re-prompt and the user must use System Settings.
          final granted =
              await NotificationDisplay.instance.requestMacOSPermission();
          if (granted) {
            _permissionDenied = false;
            await _savePromptState(NotificationPromptState.optedIn);
            return NotificationPermissionResult.granted;
          }
          _permissionDenied = true;
          await _savePromptState(NotificationPromptState.declined);
          return NotificationPermissionResult.deniedPermanently;
        }
        // Windows: no permission required.
        _permissionDenied = false;
        await _savePromptState(NotificationPromptState.optedIn);
        return NotificationPermissionResult.granted;
      } catch (e) {
        log.warning('Failed to initialize desktop notifications', e);
        return NotificationPermissionResult.error;
      }
    }

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.getNotificationSettings();

    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      _permissionDenied = false;
      if (!_tokenRegistered) {
        _retryCount = 0;
        await _ensureTokenListenerAndRegister();
      }
      await _savePromptState(NotificationPromptState.optedIn);
      return NotificationPermissionResult.granted;
    }

    // NOT granted (Android: also the fresh-install state; iOS: notDetermined or
    // denied). Always ask — the OS shows the dialog only when askable.
    final wasFirstAsk = _loadPromptState() == NotificationPromptState.unset;
    try {
      final result = await messaging.requestPermission();
      final granted =
          result.authorizationStatus == AuthorizationStatus.authorized ||
          result.authorizationStatus == AuthorizationStatus.provisional;
      switch (mapRequestOutcome(granted: granted, wasFirstAsk: wasFirstAsk)) {
        case NotificationPromptOutcome.granted:
          _permissionDenied = false;
          _retryCount = 0;
          await _ensureTokenListenerAndRegister();
          await _savePromptState(NotificationPromptState.optedIn);
          return NotificationPermissionResult.granted;
        case NotificationPromptOutcome.declined:
          _permissionDenied = true;
          await _savePromptState(NotificationPromptState.declined);
          return NotificationPermissionResult.denied;
        case NotificationPromptOutcome.openSettings:
          _permissionDenied = true;
          await _savePromptState(NotificationPromptState.declined);
          return NotificationPermissionResult.deniedPermanently;
      }
    } catch (e) {
      log.warning('Failed to request notification permission', e);
      return NotificationPermissionResult.error;
    }
  }
```

- [ ] **Step 5: Simplify resume handling; remove dead `_recheckPermission`**

Replace `didChangeAppLifecycleState` (old lines 509–526) with:

```dart
  /// Re-register on app resume (mobile only): reconcile token registration with
  /// the current OS permission. The re-enable *prompt* is driven by
  /// [NotificationPromptCoordinator], which also re-evaluates on resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isMobile) return;
    if (state != AppLifecycleState.resumed || !_started) return;
    unawaited(_reconcileIfGranted());
  }
```

Delete the now-unused `_recheckPermission()` method (old lines 528–541).
Add `import 'dart:async';` if `unawaited` is not already available (it is — the
file already imports `dart:async` at line 1).

- [ ] **Step 6: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze`
Expected: No issues (in particular, no "unused element" for removed methods, no
missing imports). Also re-run Task 1's test to confirm no regression:
`flutter test test/notifications/notification_prompt_test.dart` → PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/notifications/notification_service.dart
git commit -m "fix(notifications): prompt on Android fresh install; defer OS prompt to user action

getNotificationSettings() never returns notDetermined on Android, so the
denied early-return suppressed the OS prompt on fresh installs. Always call
requestPermission() (OS decides whether to show the dialog), track per-device
opt-in state, add evaluate()/declineFromUser(), and stop auto-prompting on
sign-in (the prompt is now user-driven via the priming modal)."
```

---

### Task 3: NotificationPromptCoordinator widget + mount in app shell

**Files:**
- Create: `apps/plot/lib/notifications/notification_prompt_coordinator.dart`
- Modify: `apps/plot/lib/widget/app_shell.dart`

**Interfaces:**
- Consumes: `NotificationService.evaluate()` / `requestPermission()` /
  `declineFromUser()` / `openSystemNotificationSettings()` (Task 2);
  `NotificationPromptAction` (Task 1); `OnboardingBloc`/`OnboardingState`,
  `UserBloc`/`UserState`, `ConfirmModal`, `Scenes`, `context.showToast`.
- Produces: `NotificationPromptCoordinator` widget (zero-size).

Verified by `flutter analyze` here and the run-app pass in Task 5 (the modal is
gated on the Firebase-backed `evaluate()`, so there is no lightweight unit test).

- [ ] **Step 1: Create the coordinator**

Create `apps/plot/lib/notifications/notification_prompt_coordinator.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/notifications/notification_prompt.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/screenshot/scenes.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/state/user.dart';
import 'package:plot/widget/confirm_modal.dart';
import 'package:plot/widget/toast.dart';

/// Decides *when* to surface the notification opt-in prompt. Mounted in the app
/// shell under `ModalProvider`, with `OnboardingBloc`/`UserBloc` in scope.
///
/// Fires once per launch when onboarding has resolved (`OnboardingCompleted`)
/// and the user is ready — and re-evaluates on resume so a system revocation
/// surfaces the re-enable modal. Renders nothing.
class NotificationPromptCoordinator extends StatefulWidget {
  const NotificationPromptCoordinator({super.key});

  @override
  State<NotificationPromptCoordinator> createState() =>
      _NotificationPromptCoordinatorState();
}

class _NotificationPromptCoordinatorState
    extends State<NotificationPromptCoordinator> with WidgetsBindingObserver {
  bool _modalOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Handle the already-completed case (returning users whose OnboardingBloc
    // resolved before this widget's BlocListener could observe the transition).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ob = context.read<OnboardingBloc?>()?.state;
      if (ob is OnboardingCompleted) _maybePrompt();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybePrompt();
  }

  Future<void> _maybePrompt() async {
    if (!mounted || _modalOpen) return;
    if (Scenes.active) return; // never prompt during screenshot scenes
    if (context.read<UserBloc>().state is! UserReady) return;
    if (context.read<OnboardingBloc?>()?.state is! OnboardingCompleted) return;

    final action = await NotificationService.instance.evaluate();
    if (!mounted) return;
    switch (action) {
      case NotificationPromptAction.none:
        return;
      case NotificationPromptAction.showPriming:
        await _show(
          title: 'Stay on top of what matters',
          message: 'Get notified when important threads need your attention '
              '— even when Plot is closed.',
        );
      case NotificationPromptAction.showReEnable:
        await _show(
          title: 'Notifications are turned off',
          message: 'Turn them back on so Plot can alert you about important '
              'threads.',
        );
    }
  }

  Future<void> _show({required String title, required String message}) async {
    _modalOpen = true;
    bool enable = false;
    try {
      enable = await ConfirmModal(
        title: title,
        message: message,
        confirmLabel: 'Enable notifications',
        cancelLabel: 'Not now',
      ).run(context);
    } finally {
      _modalOpen = false;
    }
    if (!mounted) return;

    if (!enable) {
      await NotificationService.instance.declineFromUser();
      return;
    }

    final result = await NotificationService.instance.requestPermission();
    if (!mounted) return;
    switch (result) {
      case NotificationPermissionResult.granted:
        context.showToast(message: 'Notifications enabled');
      case NotificationPermissionResult.deniedPermanently:
        NotificationService.instance.openSystemNotificationSettings();
        context.showToast(
          message: 'Enable notifications in your device settings, then return '
              'to Plot.',
        );
      case NotificationPermissionResult.denied:
      case NotificationPermissionResult.unsupported:
      case NotificationPermissionResult.error:
        // Denial / unsupported / transient error — no error toast needed; the
        // Settings tile remains available.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<OnboardingBloc, OnboardingState>(
      // Fire when onboarding resolves to completed (finished, skipped, or the
      // returning-user fast path). Guards inside _maybePrompt enforce once-only.
      listenWhen: (previous, current) =>
          current is OnboardingCompleted && previous is! OnboardingCompleted,
      listener: (context, _) => _maybePrompt(),
      child: const SizedBox.shrink(),
    );
  }
}
```

- [ ] **Step 2: Mount it in the app shell**

In `apps/plot/lib/widget/app_shell.dart`, add the import after line 13:

```dart
import 'package:plot/notifications/notification_prompt_coordinator.dart';
```

Add the coordinator as a child of the existing `Stack` (the one starting at
line 72, inside `OnboardingOverlay`). Insert it after the `AutoRouter(...)`
entry (after line 76) so it sits under `ModalProvider`, `OnboardingBloc`, and
`UserBloc`:

```dart
                  child: Stack(
                    children: [
                      AutoRouter(
                        placeholder: (context) => const LoadingPage(),
                      ),
                      const NotificationPromptCoordinator(),
                      // OTP / confirm-account toast — declarative overlay
```

- [ ] **Step 3: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze`
Expected: No issues. Confirm the switch over `NotificationPermissionResult` is
exhaustive and `ConfirmModal`/`showToast` imports resolve.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/notifications/notification_prompt_coordinator.dart \
        apps/plot/lib/widget/app_shell.dart
git commit -m "feat(notifications): coordinator shows priming/re-enable modal after onboarding"
```

---

### Task 4: Settings tile copy + DRY system-settings deep-link

**Files:**
- Modify: `apps/plot/lib/command/settings.dart:706-753`

**Interfaces:**
- Consumes: `NotificationService.openSystemNotificationSettings()` (Task 2).

- [ ] **Step 1: Update `EnableNotifications` subtitle + reuse the service helper**

In `settings.dart`, update the `EnableNotifications` subtitle (lines 710–712) to
plainer copy:

```dart
        subtitle: NotificationService.instance.isPermissionDenied
            ? 'Off — enable in device settings'
            : 'Off — tap to turn on',
```

Replace the `_openSystemSettings()` method body (lines 742–752) to delegate the
macOS deep-link to the service helper (removing the duplicated `launchUrl`):

```dart
  CommandReturn _openSystemSettings() {
    NotificationService.instance.openSystemNotificationSettings();
    return CommandMessage(
      'Please enable notifications in your device settings, then return to Plot.',
    );
  }
```

If `launchUrl` / `url_launcher` is now unused in `settings.dart`, remove that
import to keep analyze clean.

- [ ] **Step 2: Verify analyze is clean**

Run: `cd apps/plot && flutter analyze`
Expected: No issues (no unused `url_launcher` import in settings.dart).

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/settings.dart
git commit -m "refactor(notifications): clearer Settings tile copy; reuse system-settings deep-link"
```

---

### Task 5: Docs + full verification

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing updates bullet**

In `docs/updates.md`, under `## Next release` add (creating the heading at the
very top if it doesn't exist, above the latest stamped version) a section:

```markdown
### Notifications

- Plot now explains why notifications help and asks to turn them on after you
  get set up — and offers to switch them back on if they ever get turned off.
```

If a `### Fixes` section is more appropriate for the Android bug, add instead/in
addition:

```markdown
### Fixes

- Fixed Android not asking for notification permission on a fresh install.
```

- [ ] **Step 2: Full analyze + pure tests**

Run:
```bash
cd apps/plot && flutter analyze && flutter test test/notifications/notification_prompt_test.dart
```
Expected: analyze clean; tests PASS.

- [ ] **Step 3: Manual verification via run-app**

Use the `run-app` skill to launch the macOS app in the isolated agent profile.
Because the agent profile is a fresh install (own DB/Clerk session), it
exercises the `unset` path. Verify:
1. After completing/landing past onboarding, the priming modal appears.
2. "Enable notifications" triggers the macOS permission request; granting shows
   the "Notifications enabled" toast and no further prompt on relaunch.
3. "Not now" dismisses and does not re-prompt on the next evaluate (state
   `declined`).
4. (If feasible) revoke notifications in macOS System Settings while state is
   `optedIn`, return to the app → the re-enable modal appears on resume.

Note macOS-only manual coverage here; Android/iOS device behavior (the OS
dialog) is covered by the corrected `requestPermission()` logic + the
`mapRequestOutcome` unit tests, and should be smoke-tested on a device before
release.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs(updates): note notification prompt + Android fresh-install fix"
```

---

## Self-Review

**Spec coverage:**
- Goal 1 (benefit-explaining prompt after onboarding, iOS/Android/macOS): Task 3 (coordinator + priming modal), gated on `OnboardingCompleted`. ✓
- Goal 2 (re-enable using same modal): Task 1 `showReEnable` + Task 3 re-enable copy via the same `ConfirmModal`. ✓
- Goal 3 (always opt-out, respected): Task 2 `declineFromUser` + `decidePromptAction(declined → none)`. ✓
- Goal 4 (per-device state): Task 2 `ProfilePreferences` keyed `notif_prompt_state:<userId>`. ✓
- Goal 5 (Android bug fix): Task 2 Step 4 (`requestPermission` no longer bails on Android `denied`). ✓
- Non-goal "no new badge": honored (Task 4 keeps the existing tile only). ✓
- Non-goal "no new dependency": honored (no `permission_handler`). ✓
- Non-goal "reconcile existing users silently": Task 2 `_reconcileIfGranted` sets `optedIn` when granted, so `evaluate()` returns `none`. ✓
- Windows prompt-less: Task 2 `_isOsGranted` returns true on Windows → `evaluate` none. ✓
- Screenshot scenes: Task 3 `_maybePrompt` early-returns on `Scenes.active`. ✓

**Placeholder scan:** No TBD/TODO; all code steps contain full code; commands have expected output.

**Type consistency:** `NotificationPromptState` / `NotificationPromptAction` /
`NotificationPromptOutcome`, `evaluate()`, `requestPermission()`,
`declineFromUser()`, `openSystemNotificationSettings()`,
`_reconcileIfGranted()`, `_ensureTokenListenerAndRegister()`,
`_loadPromptState()`/`_savePromptState()` are used with identical signatures
across Tasks 1–4. `ConfirmModal.run` → `Future<bool>` and the
`NotificationPermissionResult` enum values match the existing definitions.
