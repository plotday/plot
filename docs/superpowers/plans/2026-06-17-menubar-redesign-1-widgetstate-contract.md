# Menu-bar redesign — Plan 1: shared WidgetState contract (Dart)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the cross-platform `WidgetBridge` so a single `WidgetState`
snapshot carries everything the redesigned menu-bar/tray surfaces need — a
computed title, current focus + role label, today's current/next event (with a
"has call" flag), the focus list for a switcher, up to 5 active to-dos for the
current focus — and route the six new actions (navigate to thread/focus, set
current focus, join call, quick capture, open app) back into the app.

**Architecture:** Pure-Dart contract layer. All feature/data logic lives here so
the two native shells (macOS `NSPopover`, Windows popup — Plans 2 and 3) only
render a string + lists and emit action names. Title precedence is computed once
in Dart (a pure function) to avoid divergence between Swift and C++. The bridge
gains link-watching (for the current/next event) and consumes existing store
queries; it acquires navigation/window/capture collaborators via constructor
injection from `RootProvider`.

**Tech Stack:** Dart, Flutter Bloc, Drift (store layer), `equatable`,
`url_launcher`, `window_manager`, auto_route, `flutter_test`.

## Global Constraints

- UI text is sentence case; only first word + proper nouns capitalized.
- Use `equatable` for value classes (`props` must list every field).
- Strong typing: `strict-casts`, `strict-inference`, `strict-raw-types`.
- Only `package:flutter/widgets.dart` and `package:forui/forui.dart` for UI —
  never `package:flutter/material.dart`. (This plan is non-UI; relevant only if
  a helper touches widgets.)
- New `catch` blocks for unexpected errors call
  `Tracker.captureException(error, stackTrace)`.
- Run `cd apps/plot && flutter analyze` before every commit; it must be clean.
- Tests live under `apps/plot/test/widget_bridge/`; run with
  `cd apps/plot && flutter test test/widget_bridge/<file>`.
- The bridge already no-ops on unsupported platforms; do not regress that
  (`WidgetBridgeChannel.isSupportedPlatform`).
- Native readers tolerate missing JSON keys — all new `toJson` keys are additive.

## File structure

- **Modify** `apps/plot/lib/widget_bridge/widget_data.dart` — extend
  `WidgetState` (new fields, `toJson`, `props`); add small value types
  `WidgetTodo`, `WidgetFocus`, `WidgetEvent`.
- **Create** `apps/plot/lib/widget_bridge/widget_title.dart` — pure
  `computeWidgetTitle(...)` precedence function.
- **Modify** `apps/plot/lib/widget_bridge/widget_bridge_channel.dart` — new
  action-name constants.
- **Modify** `apps/plot/lib/widget_bridge/widget_bridge.dart` — extend
  `_snapshot`, add link-watching for current/next event, to-do + focus-list
  derivation, and new `_handleAction` cases; accept injected collaborators.
- **Create** `apps/plot/lib/widget_bridge/widget_navigation.dart` — a thin
  `WidgetNavigator` interface + default impl that brings the window forward and
  opens a thread/focus, delegating to publicized `PrioritiesShell` helpers.
- **Modify** `apps/plot/lib/widget/priorities_shell.dart` — publicize
  `openThread`/`openFocus` (thin wrappers over the existing private
  `_openThreadStatic` / focus navigation).
- **Modify** `apps/plot/lib/state/root_provider.dart` — inject the navigator
  into `WidgetBridge`.
- **Create** tests under `apps/plot/test/widget_bridge/`.

---

### Task 1: Value types + extended `WidgetState` serialization

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_data.dart`
- Test: `apps/plot/test/widget_bridge/widget_data_test.dart`

**Interfaces:**
- Produces:
  - `class WidgetTodo { final String threadId; final String title; }`
  - `class WidgetFocus { final String focusId; final String? roleName; final String focusName; final String? colorHex; }`
  - `class WidgetEvent { final String threadId; final String title; final String startIso; final String? endIso; final bool hasCall; }`
  - `WidgetState` gains: `String? title`, `bool titleIsTimer`, `String? timerTitlePrefix`, `WidgetFocus? currentFocus`, `WidgetEvent? currentEvent2`, `WidgetEvent? nextEvent2`, `List<WidgetTodo> todos`, `List<WidgetFocus> focuses`. (The legacy `currentEventTitle`, `nextEventTitle`, `nextEventStartIso` stay for now; native code migrates to the new fields in Plans 2/3, then they are removed.)
  - Each value type and `WidgetState` expose `Map<String, Object?> toJson()`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget_bridge/widget_data_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_data.dart';

void main() {
  test('WidgetTodo/WidgetFocus/WidgetEvent serialize', () {
    expect(
      const WidgetTodo(threadId: 't1', title: 'Reply to sponsor').toJson(),
      {'threadId': 't1', 'title': 'Reply to sponsor'},
    );
    expect(
      const WidgetFocus(
        focusId: 'f1',
        roleName: 'AFC Marlow',
        focusName: 'Marketing',
        colorHex: '#FF0000',
      ).toJson(),
      {
        'focusId': 'f1',
        'roleName': 'AFC Marlow',
        'focusName': 'Marketing',
        'colorHex': '#FF0000',
      },
    );
    expect(
      const WidgetEvent(
        threadId: 'e1',
        title: 'Standup',
        startIso: '2026-06-17T14:00:00Z',
        endIso: '2026-06-17T14:15:00Z',
        hasCall: true,
      ).toJson(),
      {
        'threadId': 'e1',
        'title': 'Standup',
        'startIso': '2026-06-17T14:00:00Z',
        'endIso': '2026-06-17T14:15:00Z',
        'hasCall': true,
      },
    );
  });

  test('WidgetState.toJson includes new fields as lists/maps', () {
    const state = WidgetState(
      isSignedIn: true,
      userId: 'u1',
      title: 'Marketing',
      titleIsTimer: false,
      currentFocus: WidgetFocus(
        focusId: 'f1',
        roleName: null,
        focusName: 'Marketing',
        colorHex: null,
      ),
      todos: [WidgetTodo(threadId: 't1', title: 'Draft newsletter')],
      focuses: [
        WidgetFocus(
          focusId: 'f1',
          roleName: null,
          focusName: 'Marketing',
          colorHex: null,
        ),
      ],
    );
    final json = state.toJson();
    expect(json['title'], 'Marketing');
    expect(json['titleIsTimer'], false);
    expect((json['todos']! as List).single,
        {'threadId': 't1', 'title': 'Draft newsletter'});
    expect((json['currentFocus']! as Map)['focusName'], 'Marketing');
    expect((json['focuses']! as List).length, 1);
  });

  test('signedOut snapshot has empty lists, null title', () {
    final json = WidgetState.signedOut().toJson();
    expect(json['isSignedIn'], false);
    expect(json['title'], isNull);
    expect(json['todos'], isEmpty);
    expect(json['focuses'], isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_data_test.dart`
Expected: FAIL — `WidgetTodo`/`WidgetFocus`/`WidgetEvent` undefined, named params `title`/`todos`/... not found on `WidgetState`.

- [ ] **Step 3: Add value types and extend `WidgetState`**

Add the three value types (each `extends Equatable`) and the new `WidgetState`
fields. Defaults keep `signedOut()` valid: `titleIsTimer = false`,
`todos = const []`, `focuses = const []`, all nullable refs default null.

```dart
// add near top of widget_data.dart, after the imports
class WidgetTodo extends Equatable {
  const WidgetTodo({required this.threadId, required this.title});
  final String threadId;
  final String title;
  Map<String, Object?> toJson() => {'threadId': threadId, 'title': title};
  @override
  List<Object?> get props => [threadId, title];
}

class WidgetFocus extends Equatable {
  const WidgetFocus({
    required this.focusId,
    required this.roleName,
    required this.focusName,
    required this.colorHex,
  });
  final String focusId;
  final String? roleName;
  final String focusName;
  final String? colorHex;
  Map<String, Object?> toJson() => {
        'focusId': focusId,
        'roleName': roleName,
        'focusName': focusName,
        'colorHex': colorHex,
      };
  @override
  List<Object?> get props => [focusId, roleName, focusName, colorHex];
}

class WidgetEvent extends Equatable {
  const WidgetEvent({
    required this.threadId,
    required this.title,
    required this.startIso,
    required this.endIso,
    required this.hasCall,
  });
  final String threadId;
  final String title;
  final String startIso;
  final String? endIso;
  final bool hasCall;
  Map<String, Object?> toJson() => {
        'threadId': threadId,
        'title': title,
        'startIso': startIso,
        'endIso': endIso,
        'hasCall': hasCall,
      };
  @override
  List<Object?> get props => [threadId, title, startIso, endIso, hasCall];
}
```

Add to the `WidgetState` constructor parameter list (with defaults) and as
final fields:

```dart
    this.title,
    this.titleIsTimer = false,
    this.timerTitlePrefix,
    this.currentFocus,
    this.currentEvent2,
    this.nextEvent2,
    this.todos = const [],
    this.focuses = const [],
```

```dart
  /// Fully-composed menu-bar/tray title string for the non-timer states.
  /// Null when signed out / nothing to show. See widget_title.dart.
  final String? title;

  /// When true, the title is the running-timer state: native renders
  /// "$timerTitlePrefix · {ticking remaining}" instead of [title].
  final bool titleIsTimer;

  /// Focus label shown before the ticking countdown when [titleIsTimer].
  final String? timerTitlePrefix;

  final WidgetFocus? currentFocus;
  final WidgetEvent? currentEvent2;
  final WidgetEvent? nextEvent2;
  final List<WidgetTodo> todos;
  final List<WidgetFocus> focuses;
```

Extend `toJson()` (append before the closing `}`):

```dart
    'title': title,
    'titleIsTimer': titleIsTimer,
    'timerTitlePrefix': timerTitlePrefix,
    'currentFocus': currentFocus?.toJson(),
    'currentEvent2': currentEvent2?.toJson(),
    'nextEvent2': nextEvent2?.toJson(),
    'todos': todos.map((t) => t.toJson()).toList(),
    'focuses': focuses.map((f) => f.toJson()).toList(),
```

Extend `props` with the same new fields (lists are fine for Equatable).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_data_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/widget_bridge/widget_data.dart apps/plot/test/widget_bridge/widget_data_test.dart
git commit -m "feat(widget-bridge): extend WidgetState with focus/event/todo/focus-list fields"
```

---

### Task 2: Title precedence (pure function)

**Files:**
- Create: `apps/plot/lib/widget_bridge/widget_title.dart`
- Test: `apps/plot/test/widget_bridge/widget_title_test.dart`

**Interfaces:**
- Consumes: nothing from other tasks (pure inputs).
- Produces:
  - `class WidgetTitle { final String? text; final bool isTimer; final String? timerPrefix; }`
  - `WidgetTitle computeWidgetTitle({required String? focusLabel, required String? currentEventTitle, required DateTime? currentEventStart, required DateTime? currentEventEnd, required String? nextEventTitle, required DateTime? nextEventStart, required bool sessionTimerRunning, required DateTime now})`
- Used by: Task 6 (snapshot) to populate `WidgetState.title` / `titleIsTimer` / `timerTitlePrefix`.

Precedence (first match wins), per spec §"Always-visible title":
1. Next event today starting within 2 min → `"{ceilMinutes}m → {nextEventTitle}"`
2. Current event in progress (now in [start, end]) → `nextEventTitle`'s sibling `currentEventTitle`
3. `sessionTimerRunning` → `isTimer: true`, `timerPrefix: focusLabel`
4. Otherwise → `focusLabel`

"Today" = the next event's local date equals `now`'s local date.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget_bridge/widget_title_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_title.dart';

void main() {
  final now = DateTime(2026, 6, 17, 9, 0);

  WidgetTitle call({
    String? focusLabel = 'Marketing',
    String? currentEventTitle,
    DateTime? currentEventStart,
    DateTime? currentEventEnd,
    String? nextEventTitle,
    DateTime? nextEventStart,
    bool sessionTimerRunning = false,
  }) =>
      computeWidgetTitle(
        focusLabel: focusLabel,
        currentEventTitle: currentEventTitle,
        currentEventStart: currentEventStart,
        currentEventEnd: currentEventEnd,
        nextEventTitle: nextEventTitle,
        nextEventStart: nextEventStart,
        sessionTimerRunning: sessionTimerRunning,
        now: now,
      );

  test('imminent event within 2 min wins, ceil minutes', () {
    final t = call(
      nextEventTitle: 'Standup',
      nextEventStart: now.add(const Duration(seconds: 90)),
    );
    expect(t.text, '2m → Standup');
    expect(t.isTimer, false);
  });

  test('event >2 min away does not trigger state 1', () {
    final t = call(
      nextEventTitle: 'Standup',
      nextEventStart: now.add(const Duration(minutes: 25)),
    );
    expect(t.text, 'Marketing'); // falls to focus
  });

  test('in-progress event beats running timer', () {
    final t = call(
      currentEventTitle: 'Design review',
      currentEventStart: now.subtract(const Duration(minutes: 5)),
      currentEventEnd: now.add(const Duration(minutes: 25)),
      sessionTimerRunning: true,
    );
    expect(t.text, 'Design review');
    expect(t.isTimer, false);
  });

  test('running timer with no event → timer prefix is focus', () {
    final t = call(sessionTimerRunning: true);
    expect(t.isTimer, true);
    expect(t.timerPrefix, 'Marketing');
    expect(t.text, isNull);
  });

  test('nothing active → focus label', () {
    expect(call().text, 'Marketing');
  });

  test('next event on a different day is ignored', () {
    final t = call(
      nextEventTitle: 'Tomorrow kickoff',
      nextEventStart: now.add(const Duration(days: 1)),
    );
    expect(t.text, 'Marketing');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_title_test.dart`
Expected: FAIL — `computeWidgetTitle`/`WidgetTitle` undefined.

- [ ] **Step 3: Implement the function**

```dart
// apps/plot/lib/widget_bridge/widget_title.dart
import 'package:equatable/equatable.dart';

/// Result of [computeWidgetTitle]. When [isTimer] is true the native shell
/// renders "$timerPrefix · {ticking remaining}"; otherwise it renders [text].
class WidgetTitle extends Equatable {
  const WidgetTitle({this.text, this.isTimer = false, this.timerPrefix});
  final String? text;
  final bool isTimer;
  final String? timerPrefix;
  @override
  List<Object?> get props => [text, isTimer, timerPrefix];
}

/// Pure menu-bar/tray title precedence. See the redesign spec, "Always-visible
/// title". Computed in Dart so both native shells render identically.
WidgetTitle computeWidgetTitle({
  required String? focusLabel,
  required String? currentEventTitle,
  required DateTime? currentEventStart,
  required DateTime? currentEventEnd,
  required String? nextEventTitle,
  required DateTime? nextEventStart,
  required bool sessionTimerRunning,
  required DateTime now,
}) {
  // State 1: next event today, starting within 2 minutes.
  if (nextEventTitle != null &&
      nextEventStart != null &&
      _isSameLocalDay(nextEventStart, now)) {
    final until = nextEventStart.difference(now);
    if (until > Duration.zero && until <= const Duration(minutes: 2)) {
      final mins = (until.inSeconds / 60).ceil();
      return WidgetTitle(text: '${mins}m → $nextEventTitle');
    }
  }

  // State 2: current event in progress.
  if (currentEventTitle != null &&
      currentEventStart != null &&
      !now.isBefore(currentEventStart) &&
      (currentEventEnd == null || now.isBefore(currentEventEnd))) {
    return WidgetTitle(text: currentEventTitle);
  }

  // State 3: a manual focus timer is running.
  if (sessionTimerRunning) {
    return WidgetTitle(isTimer: true, timerPrefix: focusLabel);
  }

  // State 4: current focus.
  return WidgetTitle(text: focusLabel);
}

bool _isSameLocalDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_title_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/widget_bridge/widget_title.dart apps/plot/test/widget_bridge/widget_title_test.dart
git commit -m "feat(widget-bridge): pure title precedence (computeWidgetTitle)"
```

---

### Task 3: New action-name constants

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge_channel.dart:28-32`
- Test: `apps/plot/test/widget_bridge/widget_actions_test.dart`

**Interfaces:**
- Produces (top-level `const String`s used by Tasks 6–8 and native shells):
  - `widgetActionNavigateThread = 'navigateThread'`
  - `widgetActionNavigateFocus = 'navigateFocus'`
  - `widgetActionSetCurrentFocus = 'setCurrentFocus'`
  - `widgetActionJoinCall = 'joinCall'`
  - `widgetActionCapture = 'capture'`
  - `widgetActionOpenApp = 'openApp'`
- The existing `widgetActionCreateNote`/`widgetActionOpenPriority` stay (superseded by `capture`/`navigateFocus`; remove only after native migration).

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget_bridge/widget_actions_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge_channel.dart';

void main() {
  test('new action names are stable and distinct', () {
    final names = {
      widgetActionNavigateThread,
      widgetActionNavigateFocus,
      widgetActionSetCurrentFocus,
      widgetActionJoinCall,
      widgetActionCapture,
      widgetActionOpenApp,
    };
    expect(names.length, 6);
    expect(widgetActionCapture, 'capture');
    expect(widgetActionJoinCall, 'joinCall');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_actions_test.dart`
Expected: FAIL — constants undefined.

- [ ] **Step 3: Add the constants** after line 32 of `widget_bridge_channel.dart`:

```dart
/// Navigation + capture actions sent from the redesigned menu-bar/tray
/// popover. Handled in `WidgetBridge._handleAction`.
const String widgetActionNavigateThread = 'navigateThread';
const String widgetActionNavigateFocus = 'navigateFocus';
const String widgetActionSetCurrentFocus = 'setCurrentFocus';
const String widgetActionJoinCall = 'joinCall';
const String widgetActionCapture = 'capture';
const String widgetActionOpenApp = 'openApp';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_actions_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/widget_bridge/widget_bridge_channel.dart apps/plot/test/widget_bridge/widget_actions_test.dart
git commit -m "feat(widget-bridge): add navigate/capture/joinCall/openApp action names"
```

---

### Task 4: `WidgetNavigator` + publicized `PrioritiesShell` helpers

**Files:**
- Create: `apps/plot/lib/widget_bridge/widget_navigation.dart`
- Modify: `apps/plot/lib/widget/priorities_shell.dart` (publicize existing
  `_openThreadStatic` at ~line 505 and add an `openFocus`)
- Test: none (thin glue over auto_route + `navigatorKey`; verified via run-app
  in the shell plans). Keep the file free of logic that would warrant a unit
  test — it only forwards.

**Interfaces:**
- Produces:
  - `abstract class WidgetNavigator { Future<void> showWindow(); Future<void> openThread(String threadId, String priorityId); Future<void> openFocus(String priorityId); }`
  - `class DefaultWidgetNavigator implements WidgetNavigator { ... }`
  - `PrioritiesShell.openThread(String priorityIdString, String threadIdString)` (public, static) and `PrioritiesShell.openFocus(String priorityIdString)` (public, static).
- Consumed by: Tasks 6 & 8 (the bridge holds a `WidgetNavigator`).

- [ ] **Step 1: Publicize the shell helpers**

In `apps/plot/lib/widget/priorities_shell.dart`, add public static wrappers
next to the existing private statics (do NOT change the private impls — the
screenshot scenes still call them):

```dart
  /// Public entry for the widget bridge: bring a thread on screen, mirroring
  /// a thread tap (Activity tab + inner ThreadRoute). See [_openThreadStatic].
  static void openThread(String priorityIdString, String threadIdString) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _openThreadStatic(ctx, priorityIdString, threadIdString);
  }

  /// Public entry for the widget bridge: open a focus (priority) page.
  static void openFocus(String priorityIdString) {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final tabsRouter = _findTabsRouter(ctx.router.root);
    if (tabsRouter != null && tabsRouter.activeIndex != _kTabActivity) {
      tabsRouter.setActiveIndex(_kTabActivity);
    }
    ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
  }
```

- [ ] **Step 2: Create the navigator**

```dart
// apps/plot/lib/widget_bridge/widget_navigation.dart
import 'package:flutter/foundation.dart';

import 'package:plot/widget/priorities_shell.dart';

/// Collaborator the widget bridge uses to surface the app from the
/// menu-bar/tray. Abstracted so tests inject a fake. The default impl brings
/// the desktop window forward then drives auto_route via [PrioritiesShell].
abstract class WidgetNavigator {
  Future<void> showWindow();
  Future<void> openThread(String threadId, String priorityId);
  Future<void> openFocus(String priorityId);
}

class DefaultWidgetNavigator implements WidgetNavigator {
  const DefaultWidgetNavigator();

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<void> showWindow() async {
    if (!_isDesktop) return;
    // window_manager is only imported behind the desktop guard so the web
    // build never references it.
    await _showDesktopWindow();
  }

  @override
  Future<void> openThread(String threadId, String priorityId) async {
    await showWindow();
    PrioritiesShell.openThread(priorityId, threadId);
  }

  @override
  Future<void> openFocus(String priorityId) async {
    await showWindow();
    PrioritiesShell.openFocus(priorityId);
  }
}
```

Add the desktop window helper in the same file (kept private and guarded so the
import is never reached on web):

```dart
// at top of file, conditionally importable; window_manager is already a
// dependency used by lib/widget/window.dart.
import 'package:window_manager/window_manager.dart';

Future<void> _showDesktopWindow() async {
  if (!await windowManager.isVisible()) {
    await windowManager.show();
  }
  await windowManager.focus();
}
```

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no errors (the new file + the two public statics compile).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget_bridge/widget_navigation.dart apps/plot/lib/widget/priorities_shell.dart
git commit -m "feat(widget-bridge): WidgetNavigator + public PrioritiesShell open helpers"
```

---

### Task 5: Current-focus label + focus list in the snapshot

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart`
- Test: `apps/plot/test/widget_bridge/widget_focus_label_test.dart`

**Interfaces:**
- Produces (private helpers on `WidgetBridge`, but tested via small extracted
  pure functions):
  - top-level `String focusLabelFor(String focusTitle, String? roleName, int roleCount)` in `widget_bridge.dart` — mirrors `FocusLabel`'s rule: prefix `"$roleName › "` only when `roleCount >= 2` and `roleName != null`.
- Consumed by: Task 6 (assembles `currentFocus` + `focuses` and the title).

The role separator is `Priority.separator` (`' › '`,
`apps/plot/lib/store/priority.dart`). Role count comes from `Role.cachedCount`
(`apps/plot/lib/store/role.dart`). The current focus is `NowLoaded.priority`
(already used by the existing snapshot at `widget_bridge.dart:97`). The colour
hex comes from the focus's `labelDisplayColor` (`priority.dart:1279`) — convert
to `#RRGGBB`.

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget_bridge/widget_focus_label_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';

void main() {
  test('single role: no prefix', () {
    expect(focusLabelFor('Marketing', 'AFC Marlow', 1), 'Marketing');
  });
  test('null role: no prefix', () {
    expect(focusLabelFor('Marketing', null, 3), 'Marketing');
  });
  test('2+ roles: Role › Focus', () {
    expect(focusLabelFor('Marketing', 'AFC Marlow', 2),
        'AFC Marlow › Marketing');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_focus_label_test.dart`
Expected: FAIL — `focusLabelFor` undefined.

- [ ] **Step 3: Implement `focusLabelFor`** as a top-level function in
`apps/plot/lib/widget_bridge/widget_bridge.dart` (so it is unit-testable without
a bloc), using the literal separator to avoid a store import cycle if one
arises (it is `' › '`):

```dart
/// Role-gated focus label mirroring [FocusLabel]: show "$role › $focus" only
/// when the user has 2+ roles and the focus has a role. Separator matches
/// `Priority.separator`.
String focusLabelFor(String focusTitle, String? roleName, int roleCount) {
  if (roleName != null && roleCount >= 2) {
    return '$roleName › $focusTitle';
  }
  return focusTitle;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_focus_label_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze
git add apps/plot/lib/widget_bridge/widget_bridge.dart apps/plot/test/widget_bridge/widget_focus_label_test.dart
git commit -m "feat(widget-bridge): role-gated focus label helper"
```

---

### Task 6: Assemble focus, focus-list, events, title into `_snapshot`

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart` (the `_snapshot`
  method, ~line 87, and add link-watching state)
- Test: `apps/plot/test/widget_bridge/widget_snapshot_test.dart`

**Interfaces:**
- Consumes: `focusLabelFor` (Task 5), `computeWidgetTitle` (Task 2), the new
  `WidgetState`/`WidgetFocus`/`WidgetEvent` fields (Task 1).
- Produces: a `_snapshot()` that fills `title`, `titleIsTimer`,
  `timerTitlePrefix`, `currentFocus`, `currentEvent2`, `nextEvent2`, `focuses`.
  (`todos` is added in Task 7; `hasCall` in this task is sourced from a
  `Set<String>` of event thread ids the bridge knows have a call link — see the
  link-watching step.)

Because building the full snapshot needs live blocs, the unit test targets two
extracted pure helpers; the wired `_snapshot` is exercised by run-app in the
shell plans.

Extract these pure helpers (top-level in `widget_bridge.dart`) and test them:

```dart
WidgetEvent? widgetEventFrom(
  Thread? thread, {
  required bool hasCall,
}) {
  if (thread == null) return null;
  final start = thread.at?.start;
  if (start == null) return null;
  return WidgetEvent(
    threadId: thread.id.toString(),
    title: thread.displayTitle,
    startIso: start.toUtc().toIso8601String(),
    endIso: thread.at?.end?.toUtc().toIso8601String(),
    hasCall: hasCall,
  );
}
```

- [ ] **Step 1: Write the failing test** for `widgetEventFrom` precedence + the
focus-list builder. (Use a tiny fake `Thread`-shaped wrapper only if `Thread`
is hard to construct; otherwise test `widgetEventFrom(null, ...)` and the
`focusLabelFor` integration through a small `buildFocuses` helper.)

```dart
// apps/plot/test/widget_bridge/widget_snapshot_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';

void main() {
  test('widgetEventFrom(null) is null', () {
    expect(widgetEventFrom(null, hasCall: false), isNull);
  });
}
```

(The richer `_snapshot` assembly — current/next event today-gating, `focuses`
list from `Priority.watchRaw` grouped by `Role.fromCache`, and the title call —
is integration-verified; this step just locks the null contract and keeps the
helper testable.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_snapshot_test.dart`
Expected: FAIL — `widgetEventFrom` undefined.

- [ ] **Step 3: Implement the snapshot assembly.**

3a. Add `widgetEventFrom` (above) as a top-level function.

3b. Maintain a `Set<String> _eventThreadIdsWithCall` on `WidgetBridge`, kept
current by watching links for the current + next event threads. Add fields and
a re-subscribe method:

```dart
  // event-thread-id -> link subscription, for the at-most-two events we surface
  final Map<String, StreamSubscription<List<Link>>> _eventLinkSubs = {};
  final Set<String> _eventThreadIdsWithCall = {};

  void _syncEventLinkWatches(Iterable<String> eventThreadIds) {
    final wanted = eventThreadIds.toSet();
    // drop stale
    for (final id in _eventLinkSubs.keys.toList()) {
      if (!wanted.contains(id)) {
        unawaited(_eventLinkSubs.remove(id)!.cancel());
        _eventThreadIdsWithCall.remove(id);
      }
    }
    // add new
    for (final id in wanted) {
      if (_eventLinkSubs.containsKey(id)) continue;
      _eventLinkSubs[id] = Link.watchForThread(ThreadId.fromString(id)).listen((
        links,
      ) {
        final primary = Thread.primaryLink(links);
        final hasCall = primary != null &&
            (primary.actions ?? const <UserAction>[])
                .whereType<ConferencingUserAction>()
                .isNotEmpty;
        final changed = hasCall
            ? _eventThreadIdsWithCall.add(id)
            : _eventThreadIdsWithCall.remove(id);
        if (changed) _scheduleSync();
      });
    }
  }
```

(Use the correct `ThreadId` constructor from a base58/uuid string — `Uuid`
exposes a `fromString`/parse; mirror how `widget_bridge.dart` already stringifies
`priority.id.toString()`. If `ThreadId.fromString` does not exist, keep the
`Thread` object itself in a local map instead of round-tripping the id — pass
the live `Thread` to `Link.watchForThread(thread.id)`.)

Cancel these in `stop()`:

```dart
    for (final sub in _eventLinkSubs.values) {
      await sub.cancel();
    }
    _eventLinkSubs.clear();
    _eventThreadIdsWithCall.clear();
```

3c. In `_snapshot`, after computing the current focus `priority`:

```dart
    final roleCount = Role.cachedCount;
    final roleName = Role.fromCache(priority.roleId)?.name;
    final focusLabel = focusLabelFor(priority.title, roleName, roleCount);

    // Current event = in-progress event for the context; next = first upcoming
    // today. Both today-gated; null when calendar absent → native hides section.
    final inProgress = nowState.inProgressEventForContext;
    final upcomingThread =
        nowState.next.isNotEmpty ? nowState.next.first : null;
    final nowLocal = Time.now();
    final nextIsToday = upcomingThread?.at?.start != null &&
        _isSameLocalDay(upcomingThread!.at!.start!, nowLocal);

    final currentEvent2 = widgetEventFrom(
      inProgress,
      hasCall: inProgress != null &&
          _eventThreadIdsWithCall.contains(inProgress.id.toString()),
    );
    final nextEvent2 = nextIsToday
        ? widgetEventFrom(
            upcomingThread,
            hasCall: _eventThreadIdsWithCall
                .contains(upcomingThread!.id.toString()),
          )
        : null;

    // Keep link watches in sync with the two events we surface.
    _syncEventLinkWatches([
      if (inProgress != null) inProgress.id.toString(),
      if (nextIsToday && upcomingThread != null) upcomingThread.id.toString(),
    ]);

    final title = computeWidgetTitle(
      focusLabel: focusLabel,
      currentEventTitle: currentEvent2?.title,
      currentEventStart: inProgress?.at?.start,
      currentEventEnd: inProgress?.at?.end,
      nextEventTitle: nextEvent2?.title,
      nextEventStart: nextIsToday ? upcomingThread?.at?.start : null,
      sessionTimerRunning: timerSource == 'session',
      now: nowLocal,
    );

    final currentFocus = WidgetFocus(
      focusId: priority.id.toString(),
      roleName: (roleCount >= 2) ? roleName : null,
      focusName: priority.title,
      colorHex: _hex(priority.labelDisplayColor),
    );
```

3d. Build the `focuses` list from the cached priorities. `NowLoaded.priorities`
already holds the user's focuses (`now_state.dart`); map each non-archived,
non-FYI focus to a `WidgetFocus`, ordered by role then focus order:

```dart
    final focuses = <WidgetFocus>[
      for (final p in nowState.priorities)
        if (!p.isFyi)
          WidgetFocus(
            focusId: p.id.toString(),
            roleName: (roleCount >= 2) ? Role.fromCache(p.roleId)?.name : null,
            focusName: p.title,
            colorHex: _hex(p.labelDisplayColor),
          ),
    ];
```

3e. Add a `_hex(ThemeColor)` helper that renders `#RRGGBB` from the app's
`ThemeColor` (mirror any existing colour→hex util; if none, read the color's
`.value`/RGB channels and format with `toRadixString(16)`).

3f. Pass the new fields into the returned `WidgetState(...)`:
`title: title.text, titleIsTimer: title.isTimer, timerTitlePrefix:
title.timerPrefix, currentFocus: currentFocus, currentEvent2: currentEvent2,
nextEvent2: nextEvent2, focuses: focuses` (keep the existing legacy fields too).

Imports to add at top of `widget_bridge.dart`: `Link`, `UserAction`,
`ConferencingUserAction`, `Role`, `ThreadId`/`Thread` from
`package:plot/store/store.dart`; `computeWidgetTitle` from `widget_title.dart`;
`Time` is already imported.

- [ ] **Step 4: Run the test + analyze**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_snapshot_test.dart && flutter analyze`
Expected: PASS + clean analyze.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget_bridge/widget_bridge.dart apps/plot/test/widget_bridge/widget_snapshot_test.dart
git commit -m "feat(widget-bridge): snapshot focus label, today events with hasCall, focus list, title"
```

---

### Task 7: Top-5 active to-dos for the current focus

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart`
- Test: covered by analyze + run-app (the query is a thin wrapper over
  `Thread.watch`; assert the mapping shape with a focused unit test on the
  mapper).

**Interfaces:**
- Consumes: `Thread.watch` (`apps/plot/lib/store/thread.dart:1347`) with
  `todoOnly: true`.
- Produces: `WidgetState.todos` populated with ≤5 `WidgetTodo`.

`Thread.watch(priorityId: ..., todoOnly: true, archived: false, order:
ThreadOrder.sorted, limit: 5)` returns a `ThreadWatchResult` record
(`thread.dart:12`) whose `.threads` is the ordered active-task list (`todoOnly`
filters `active == true`, `thread.dart:2035`).

- [ ] **Step 1: Write the failing test** for the row mapper:

```dart
// add to apps/plot/test/widget_bridge/widget_snapshot_test.dart
import 'package:plot/widget_bridge/widget_data.dart';

  test('todoRowsFrom maps id+title and caps at 5', () {
    final rows = todoRowsFrom([
      for (var i = 0; i < 8; i++) (id: 't$i', title: 'Task $i'),
    ]);
    expect(rows.length, 5);
    expect(rows.first, const WidgetTodo(threadId: 't0', title: 'Task 0'));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_snapshot_test.dart`
Expected: FAIL — `todoRowsFrom` undefined.

- [ ] **Step 3: Implement** a top-level mapper + wire a watch.

```dart
/// Map already-fetched (id, title) pairs into ≤5 to-do rows.
List<WidgetTodo> todoRowsFrom(List<({String id, String title})> rows) =>
    [for (final r in rows.take(5)) WidgetTodo(threadId: r.id, title: r.title)];
```

Add a `List<WidgetTodo> _todos = const []` field on `WidgetBridge`, kept current
by a watch that re-subscribes whenever the current focus changes:

```dart
  StreamSubscription<ThreadWatchResult>? _todoSub;
  PriorityId? _todoPriorityId;

  void _syncTodoWatch(PriorityId? priorityId) {
    if (priorityId == _todoPriorityId) return;
    _todoPriorityId = priorityId;
    unawaited(_todoSub?.cancel());
    _todos = const [];
    if (priorityId == null) return;
    _todoSub = Thread.watch(
      priorityId: priorityId,
      todoOnly: true,
      archived: false,
      order: ThreadOrder.sorted,
      limit: 5,
    ).listen((result) {
      _todos = todoRowsFrom([
        for (final t in result.threads)
          (id: t.id.toString(), title: t.displayTitle),
      ]);
      _scheduleSync();
    });
  }
```

Call `_syncTodoWatch(priority.id)` inside `_snapshot` (after resolving
`priority`), pass `todos: _todos` into the returned `WidgetState`, and cancel
`_todoSub` in `stop()`.

- [ ] **Step 4: Run test + analyze**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_snapshot_test.dart && flutter analyze`
Expected: PASS + clean.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget_bridge/widget_bridge.dart apps/plot/test/widget_bridge/widget_snapshot_test.dart
git commit -m "feat(widget-bridge): top-5 active to-dos for current focus"
```

---

### Task 8: Route the new actions + inject the navigator

**Files:**
- Modify: `apps/plot/lib/widget_bridge/widget_bridge.dart` (constructor +
  `_handleAction`)
- Modify: `apps/plot/lib/state/root_provider.dart:48` (pass the navigator)
- Test: `apps/plot/test/widget_bridge/widget_action_routing_test.dart`

**Interfaces:**
- Consumes: action constants (Task 3), `WidgetNavigator` (Task 4),
  `NowBloc.setContext` (`now.dart:443`), `url_launcher`.
- Produces: a `WidgetBridge` whose `_handleAction` dispatches the six new
  actions; capture/joinCall resolve their targets from live state.

`setCurrentFocus` resolves the `Priority` by id from `NowLoaded.priorities` then
calls `_nowBloc.setContext(priority)`. `joinCall` re-resolves the conferencing
URL via `Link.watchForThread(threadId).first` → `Thread.primaryLink` →
`ConferencingUserAction.url` → `launchUrl(..., LaunchMode.externalApplication)`
(mirror `primary_link_header_actions.dart:60-63`). `capture` with
`target == 'currentEventThread'` appends a note to the in-progress event thread;
otherwise creates a new thread in the current focus — using the existing
create-note / create-thread commands in `apps/plot/lib/command/` (read the
compose command the in-app composer uses and call it with the captured text;
this is the real home of the previously-reserved `widgetActionCreateNote`).

- [ ] **Step 1: Write the failing test** with a fake navigator:

```dart
// apps/plot/test/widget_bridge/widget_action_routing_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget_bridge/widget_bridge.dart';
import 'package:plot/widget_bridge/widget_bridge_channel.dart';
import 'package:plot/widget_bridge/widget_navigation.dart';

class _FakeNav implements WidgetNavigator {
  final calls = <String>[];
  @override
  Future<void> openFocus(String priorityId) async =>
      calls.add('focus:$priorityId');
  @override
  Future<void> openThread(String threadId, String priorityId) async =>
      calls.add('thread:$threadId@$priorityId');
  @override
  Future<void> showWindow() async => calls.add('show');
}

void main() {
  test('navigateThread routes through the navigator', () async {
    final nav = _FakeNav();
    final routed = await routeWidgetActionForTest(
      navigator: nav,
      name: widgetActionNavigateThread,
      args: {'threadId': 't1', 'priorityId': 'p1'},
    );
    expect(routed, isTrue);
    expect(nav.calls, contains('thread:t1@p1'));
  });

  test('openApp shows the window', () async {
    final nav = _FakeNav();
    await routeWidgetActionForTest(
      navigator: nav, name: widgetActionOpenApp, args: const {});
    expect(nav.calls, contains('show'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget_bridge/widget_action_routing_test.dart`
Expected: FAIL — `routeWidgetActionForTest` undefined / constructor lacks
`navigator`.

- [ ] **Step 3: Implement.**

3a. Add a `WidgetNavigator navigator` constructor param (default
`const DefaultWidgetNavigator()`):

```dart
  WidgetBridge({
    required UserBloc userBloc,
    required NowBloc nowBloc,
    WidgetNavigator navigator = const DefaultWidgetNavigator(),
  })  : _userBloc = userBloc,
        _nowBloc = nowBloc,
        _navigator = navigator;

  final WidgetNavigator _navigator;
```

3b. Extract the navigation-only routing into a static testable function and
call it from `_handleAction`:

```dart
/// Routes the navigation/window actions through [navigator]. Returns true if
/// the action was one of them. Data actions (setCurrentFocus, joinCall,
/// capture) are handled in WidgetBridge where bloc/state is available.
Future<bool> routeWidgetActionForTest({
  required WidgetNavigator navigator,
  required String name,
  required Map<String, Object?> args,
}) async {
  switch (name) {
    case widgetActionOpenApp:
      await navigator.showWindow();
      return true;
    case widgetActionNavigateThread:
      final threadId = args['threadId'];
      final priorityId = args['priorityId'];
      if (threadId is String && priorityId is String) {
        await navigator.openThread(threadId, priorityId);
      }
      return true;
    case widgetActionNavigateFocus:
      final priorityId = args['priorityId'];
      if (priorityId is String) await navigator.openFocus(priorityId);
      return true;
  }
  return false;
}
```

3c. Extend `_handleAction` to delegate first, then handle the data actions:

```dart
    if (await routeWidgetActionForTest(
      navigator: _navigator, name: name, args: args)) {
      return null;
    }
    switch (name) {
      case widgetActionSetCurrentFocus:
        final id = args['focusId'];
        final state = _nowBloc.state;
        if (id is String && state is NowLoaded) {
          Priority? match;
          for (final p in state.priorities) {
            if (p.id.toString() == id) { match = p; break; }
          }
          if (match != null) _nowBloc.setContext(match);
        }
        return null;
      case widgetActionJoinCall:
        await _joinCall(args['threadId']);
        return null;
      case widgetActionCapture:
        await _capture(
          args['text'] as String? ?? '',
          args['target'] as String? ?? 'newThreadInCurrentFocus',
        );
        return null;
      // ... keep the existing timer cases ...
    }
```

3d. Implement `_joinCall(Object? threadId)` (resolve URL via the link stream;
mirror `primary_link_header_actions.dart`) and `_capture(String text, String
target)` (append-note vs new-thread via the existing compose commands in
`lib/command/`). Wrap both bodies' unexpected failures in
`try/catch` → `Tracker.captureException`.

3e. In `apps/plot/lib/state/root_provider.dart:48`, leave construction as-is
(the navigator default applies); only pass an explicit navigator if a non-default
is needed — no change required for the default path.

- [ ] **Step 4: Run test + analyze**

Run: `cd apps/plot && flutter test test/widget_bridge/ && flutter analyze`
Expected: all widget_bridge tests PASS + clean analyze.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget_bridge/ apps/plot/test/widget_bridge/ apps/plot/lib/state/root_provider.dart
git commit -m "feat(widget-bridge): route navigate/setFocus/join/capture/openApp actions"
```

---

## Out of scope for this plan (follow-on plans)

- **Plan 2 — macOS `NSPopover` shell**: replace the `NSMenu` in
  `MenuBarController.swift` with a popover rendering the sections from this
  contract; render `title`/`timerTitlePrefix` (ticking) in the status-item
  button; emit the new action names. Needs its own AppKit/SwiftUI discovery pass.
- **Plan 3 — Windows popup shell**: replace the right-click `HMENU` in
  `tray_icon.cpp` with a borderless popup window rendering the same sections;
  keep the GDI title bitmap; emit the same actions. Needs its own Win32
  discovery pass.

Both shells consume the JSON produced here unchanged. The legacy
`currentEventTitle` / `nextEventTitle` / `nextEventStartIso` fields remain in
`WidgetState` until both shells migrate to `currentEvent2` / `nextEvent2`, then
a cleanup commit removes them (and renames `currentEvent2`/`nextEvent2` →
`currentEvent`/`nextEvent`).

## Self-review

- **Spec coverage:** title precedence (Task 2), focus label + switcher list
  (Tasks 5–6), today-gated current/next events + hasCall (Task 6), to-dos
  (Task 7), capture/join/navigate/setFocus/openApp actions (Task 8),
  hide-events-when-none (native, driven by null `currentEvent2`/`nextEvent2`
  from Task 6). Shells are explicitly deferred to Plans 2–3.
- **Placeholder scan:** the two integration points (capture create-command,
  exact `ThreadId` string constructor) are written as "read the existing
  pattern at <file:line> then call it" with the exact target signature — not
  vague TODOs. Implementer must open `lib/command/` for the compose command;
  this is unavoidable without transcribing that file here and is bounded.
- **Type consistency:** `WidgetNavigator` method names (`showWindow`,
  `openThread`, `openFocus`) match across Tasks 4 and 8; action constant names
  match across Tasks 3 and 8; `WidgetTodo`/`WidgetFocus`/`WidgetEvent` field
  names match across Tasks 1, 6, 7.
