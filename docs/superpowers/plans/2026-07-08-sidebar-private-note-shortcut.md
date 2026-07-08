# Sidebar Private-Note Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hover-revealed "Add private note" icon button to every focus row in the sidebar (to the left of the existing "More" button) that opens the New Thread compose flow with that focus pre-selected as a private-note target, with no roster — identical to manually picking that focus under the New Thread page's "Private note" section.

**Architecture:** Mirrors the existing "Help & Feedback" mechanism (`NewThreadPageState.feedbackRequest` / `widget.feedback` / `PrioritiesShell._openFeedbackThread`) end to end, parameterized by which focus was clicked instead of a hardcoded Inbox target. A new `NewPrivateNote` command (on a focus) returns a `CommandRoute` subclass whose `go()` calls a new `PrioritiesShell.openPrivateNote(context, priorityIdString)`, which either signals an already-live New Thread page via a new static `NewThreadPageState.noteRequest`/`requestNote(...)` pair, or pushes `NewThreadRoute(notePriorityId: ...)` (cold start / fresh push). The page applies the target through the existing `_applyDirectTarget` path — no new compose logic.

**Tech Stack:** Flutter/Dart, forui widgets, auto_route (code-generated routes via build_runner), flutter_bloc.

## Global Constraints

- UI text must be sentence case (e.g. "Add private note", not "Add Private Note") — per `apps/plot/AGENTS.md` Code Style Guidelines.
- Only `flutter/widgets.dart` and `forui/forui.dart` may be imported in UI code — never `flutter/material.dart`.
- Never apply the web pointer cursor to this button — sidebar rows use the default arrow cursor (see `apps/plot/AGENTS.md` Hints).
- Run `flutter analyze` (from `apps/plot/`) before every commit; all errors must be fixed.
- Every user-facing change needs a `docs/updates.d/` fragment (plain language, no jargon) — see Task 5.
- `PlotIcon.note` (`FontAwesomeIcons.note`) already exists and is already used elsewhere in the app, so no `FONT_CACHE_VERSION` bump is needed for this change (verify no other new `FontAwesomeIcons.*` reference is introduced).

---

## Task 1: `NewThreadPage` private-note mode primitives

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

**Interfaces:**
- Consumes: existing `ComposeTarget.focusNote({required Uuid priorityId, required BigInt? teamId, String title})` (`apps/plot/lib/widget/compose/compose_target.dart:118`), existing `Future<void> _applyDirectTarget(ComposeTarget target)` (`new_thread.dart:1697`), existing `static Future<Priority> Priority.getOne(Uuid id)` (`apps/plot/lib/store/priority.dart:485`), existing `Uuid.fromShortString(String)`.
- Produces (used by Task 2): `NewThreadPage.notePriorityId` (query param field), `static ValueNotifier<int> NewThreadPageState.noteRequest`, `static void NewThreadPageState.requestNote(String priorityIdString)`.

This task has no automated test. The codebase has zero test coverage of the analogous `feedbackRequest`/`_applyFeedbackMode`/`HelpAndFeedback` mechanism this mirrors (confirmed: no test file references `feedbackRequest`, `_applyFeedbackMode`, or `HelpAndFeedback`), and no test anywhere pumps `NewThreadPage` as a widget — the existing `test/page/new_thread_*.dart` tests exercise only pure bloc/ranking logic, not the page's route-param/static-signal wiring. Building new heavy page-pump test infrastructure here would be inconsistent with established patterns. This task's behavior is verified manually in Task 5 (which the app's own `AGENTS.md` requires for UI changes regardless).

- [ ] **Step 1: Add the `notePriorityId` query param to `NewThreadPage`**

In `apps/plot/lib/page/new_thread.dart`, find the `NewThreadPage` constructor and fields (around line 159-183):

```dart
  const NewThreadPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('sharedUrl') this.sharedUrl,
    @QueryParam('feedback') this.feedback,
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? sharedUrl;

  /// When true (set by the Help & Feedback command), the draft is pre-shared
  /// with the Plot Team group so the new Inbox thread reaches the Plot team.
  ///
  /// Nullable so the route only serialises `?feedback=true` when set — a
  /// non-null `false` default would append a redundant `?feedback=false` to
  /// every normal new-thread URL (auto_route drops null/empty query values,
  /// not `false`).
  final bool? feedback;
```

Replace with:

```dart
  const NewThreadPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('sharedUrl') this.sharedUrl,
    @QueryParam('feedback') this.feedback,
    @QueryParam('notePriorityId') this.notePriorityId,
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? sharedUrl;

  /// When true (set by the Help & Feedback command), the draft is pre-shared
  /// with the Plot Team group so the new Inbox thread reaches the Plot team.
  ///
  /// Nullable so the route only serialises `?feedback=true` when set — a
  /// non-null `false` default would append a redundant `?feedback=false` to
  /// every normal new-thread URL (auto_route drops null/empty query values,
  /// not `false`).
  final bool? feedback;

  /// Set by the [NewPrivateNote] sidebar shortcut (a focus row's hover
  /// button): the id (short string) of the focus to file a private note
  /// into. A fresh mount applies it via
  /// [NewThreadPageState._applyPrivateNoteMode]; a reused live page is
  /// instead handled via [NewThreadPageState.noteRequest].
  final String? notePriorityId;
```

- [ ] **Step 2: Add the `noteRequest`/`requestNote` static signal**

In the same file, find (around line 243-250):

```dart
  /// Monotonic "enter Help & Feedback mode" signal, mirroring [resetRequest].
  /// The [HelpAndFeedback] command bumps this so a live (AutoRoute-reused)
  /// page reconfigures itself for feedback (see [_applyFeedbackMode]); a fresh
  /// mount instead reacts to the `feedback` route param in [_initializeDraft].
  static final ValueNotifier<int> feedbackRequest = ValueNotifier<int>(0);

  /// Requests every live [NewThreadPage] enter Help & Feedback mode.
  static void requestFeedback() => feedbackRequest.value++;
```

Add immediately after it:

```dart

  /// Monotonic "enter private-note mode" signal, mirroring [feedbackRequest].
  /// The [NewPrivateNote] sidebar shortcut bumps this — carrying the target
  /// focus id in [_pendingNotePriorityId] — so a live (AutoRoute-reused) page
  /// reconfigures itself for that focus (see [_applyPrivateNoteMode]); a
  /// fresh mount instead reacts to the `notePriorityId` route param.
  static final ValueNotifier<int> noteRequest = ValueNotifier<int>(0);

  /// The focus id (short string) stashed alongside the most recent
  /// [noteRequest] bump, consumed by the live page reacting to it.
  static String? _pendingNotePriorityId;

  /// Requests every live [NewThreadPage] open a private note for
  /// [priorityIdString].
  static void requestNote(String priorityIdString) {
    _pendingNotePriorityId = priorityIdString;
    noteRequest.value++;
  }
```

- [ ] **Step 3: Track the last-seen signal value and wire the listener in `initState`/`dispose`**

Find (around line 623-631):

```dart
  /// The [feedbackRequest] value seen on the last feedback entry, mirroring
  /// [_lastResetSeen]. A fresh mount ignores the bump the [HelpAndFeedback]
  /// command fired to navigate here (it reacts to the `feedback` route param
  /// instead); only a later bump against this live page re-enters feedback.
  ///
  /// Assigned eagerly in [initState] for the same reason as [_lastResetSeen] —
  /// a `late` initializer would lazily capture a post-bump value inside the
  /// first [_onFeedbackRequested] and swallow that invocation.
  late int _lastFeedbackSeen;
```

Add immediately after it:

```dart

  /// The [noteRequest] value seen on the last private-note entry, mirroring
  /// [_lastFeedbackSeen]. A fresh mount ignores the bump the [NewPrivateNote]
  /// command fired to navigate here (it reacts to the `notePriorityId` route
  /// param instead); only a later bump against this live page re-enters
  /// private-note mode.
  ///
  /// Assigned eagerly in [initState] for the same reason as [_lastResetSeen].
  late int _lastNoteSeen;
```

Find in `initState` (around line 641-644):

```dart
    _lastResetSeen = NewThreadPageState.resetRequest.value;
    _lastFeedbackSeen = NewThreadPageState.feedbackRequest.value;
    NewThreadPageState.resetRequest.addListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.addListener(_onFeedbackRequested);
```

Replace with:

```dart
    _lastResetSeen = NewThreadPageState.resetRequest.value;
    _lastFeedbackSeen = NewThreadPageState.feedbackRequest.value;
    _lastNoteSeen = NewThreadPageState.noteRequest.value;
    NewThreadPageState.resetRequest.addListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.addListener(_onFeedbackRequested);
    NewThreadPageState.noteRequest.addListener(_onNoteRequested);
```

Find `_onFeedbackRequested` (around line 666-673):

```dart
  /// Reacts to a [HelpAndFeedback] re-invocation against this already-mounted
  /// page: reconfigures it for feedback (see [_applyFeedbackMode]).
  void _onFeedbackRequested() {
    if (!mounted) return;
    if (NewThreadPageState.feedbackRequest.value == _lastFeedbackSeen) return;
    _lastFeedbackSeen = NewThreadPageState.feedbackRequest.value;
    unawaited(_applyFeedbackMode());
  }
```

Add immediately after it:

```dart

  /// Reacts to a [NewPrivateNote] re-invocation against this already-mounted
  /// page: reconfigures it for a private note (see [_applyPrivateNoteMode]).
  void _onNoteRequested() {
    if (!mounted) return;
    if (NewThreadPageState.noteRequest.value == _lastNoteSeen) return;
    _lastNoteSeen = NewThreadPageState.noteRequest.value;
    final priorityIdString = NewThreadPageState._pendingNotePriorityId;
    if (priorityIdString == null) return;
    unawaited(_applyPrivateNoteMode(priorityIdString));
  }
```

Find in `dispose` (around line 1218-1219):

```dart
    NewThreadPageState.resetRequest.removeListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.removeListener(_onFeedbackRequested);
```

Replace with:

```dart
    NewThreadPageState.resetRequest.removeListener(_onResetRequested);
    NewThreadPageState.feedbackRequest.removeListener(_onFeedbackRequested);
    NewThreadPageState.noteRequest.removeListener(_onNoteRequested);
```

- [ ] **Step 4: React to `widget.notePriorityId` on a fresh mount**

Find in `_initializeDraft` (around line 1002-1007):

```dart
    // Help & Feedback (fresh mount): configure the page for a Plot-Team chat
    // filed under Inbox. A reused live page is handled via [feedbackRequest]
    // instead (this path won't re-run — see [_hasAppliedQueryParams]).
    if (widget.feedback ?? false) {
      await _applyFeedbackMode();
    }
```

Add immediately after it (before the `// Forward (fresh mount): ...` comment that follows):

```dart

    // Private note (fresh mount): [NewPrivateNote] (the sidebar shortcut on
    // a focus row) links here via the `notePriorityId` route param. A reused
    // live page is instead handled via [noteRequest] — see
    // [_onNoteRequested].
    if (!mounted) return;
    if (widget.notePriorityId != null) {
      await _applyPrivateNoteMode(widget.notePriorityId!);
    }
```

- [ ] **Step 5: Add `_applyPrivateNoteMode`**

Find where `_applyFeedbackMode` ends (around line 1074, immediately before `Future<void> _loadConnections() async {`):

```dart
    final root = context.read<PrioritiesBloc>().state.root;
    if (root != null && root.id != bloc.state.draft.priority.id) {
      await bloc.updateDraft(bloc.state.draft.copyWith(priority: root));
    }
  }

  Future<void> _loadConnections() async {
```

Insert a new method between the closing `}` of `_applyFeedbackMode` and `_loadConnections`:

```dart
    final root = context.read<PrioritiesBloc>().state.root;
    if (root != null && root.id != bloc.state.draft.priority.id) {
      await bloc.updateDraft(bloc.state.draft.copyWith(priority: root));
    }
  }

  /// Configures the page for a private note filed into the focus identified
  /// by [priorityIdString] — the [NewPrivateNote] sidebar shortcut on a
  /// focus row. Mirrors picking that focus manually under the New Thread
  /// page's "Private note" section (see [_applyDirectTarget]). Uses
  /// `teamId: null` (Personal) — the same fallback the app's own
  /// MRU-derived focus-note templates use when a focus isn't yet
  /// represented in usage history; the user can change the
  /// connection/scope from the compose step like any other target.
  Future<void> _applyPrivateNoteMode(String priorityIdString) async {
    Priority priority;
    try {
      final priorityId = Uuid.fromShortString(priorityIdString);
      priority = await Priority.getOne(priorityId);
    } catch (e) {
      log.warning('[NewThreadPage] Failed to parse notePriorityId', e);
      return;
    }
    if (!mounted) return;
    await _applyDirectTarget(
      ComposeTarget.focusNote(
        priorityId: priority.id,
        teamId: null,
        title: priority.displayTitle,
      ),
    );
  }

  Future<void> _loadConnections() async {
```

- [ ] **Step 6: Regenerate routes**

`NewThreadRoute` (in `apps/plot/lib/router.gr.dart`) is code-generated from `NewThreadPage`'s `@QueryParam` constructor via `build_runner`. Regenerate it so `NewThreadRoute(notePriorityId: ...)` (used starting in Task 2) compiles:

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: build succeeds; `git diff apps/plot/lib/router.gr.dart` shows `NewThreadRoute`/`NewThreadRouteArgs` gaining a `notePriorityId` parameter (same shape as the existing `feedback` parameter).

- [ ] **Step 7: Analyze**

```bash
cd apps/plot && flutter analyze lib/page/new_thread.dart lib/router.gr.dart
```

Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/lib/router.gr.dart
git commit -m "feat(app): add private-note mode primitives to NewThreadPage"
```

---

## Task 2: `PrioritiesShell` navigation entry point

**Files:**
- Modify: `apps/plot/lib/widget/priorities_shell.dart`

**Interfaces:**
- Consumes: `NewThreadPageState.requestNote(String priorityIdString)` and `NewThreadRoute(notePriorityId: String?, ...)` (Task 1). Existing private helpers `_findTabsRouter`, `_findPriorityInnerRouter`, `_kTabActivity`, `ThreadHeaderNotifier.pendingNewThreadIntent`.
- Produces (used by Task 3): `static void PrioritiesShell.openPrivateNote(BuildContext context, String priorityIdString)`.

No automated test — the codebase has zero test coverage of `PrioritiesShell`'s navigation glue (`_openFeedbackThread`, `_openNewThread`, etc. are all untested; confirmed no test file references `PrioritiesShell`). This is real `RoutingController`/`AutoTabsRouter` traversal that needs the full app router tree to exercise meaningfully — verified manually in Task 5, consistent with how the mechanism it mirrors is verified today.

- [ ] **Step 1: Extend `_pushNewThreadWhenInnerReady` with a `notePriorityId` param**

Find (around line 433-454):

```dart
  static void _pushNewThreadWhenInnerReady(
    BuildContext context, {
    required int attempt,
    bool? feedback,
  }) {
    if (!context.mounted) return;
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute(feedback: feedback));
      }
      return;
    }
    if (attempt >= 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushNewThreadWhenInnerReady(
        context,
        attempt: attempt + 1,
        feedback: feedback,
      );
    });
  }
```

Replace with:

```dart
  static void _pushNewThreadWhenInnerReady(
    BuildContext context, {
    required int attempt,
    bool? feedback,
    String? notePriorityId,
  }) {
    if (!context.mounted) return;
    final innerRouter = _findPriorityInnerRouter(context.router.root);
    if (innerRouter != null) {
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(
          NewThreadRoute(feedback: feedback, notePriorityId: notePriorityId),
        );
      }
      return;
    }
    if (attempt >= 120) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushNewThreadWhenInnerReady(
        context,
        attempt: attempt + 1,
        feedback: feedback,
        notePriorityId: notePriorityId,
      );
    });
  }
```

- [ ] **Step 2: Add `_openPrivateNote`**

Find the end of `_openFeedbackThread` (around line 511-513):

```dart
    ctx.router.navigate(PriorityRoute(priorityIdString: rootPriorityIdString));
    _pushNewThreadWhenInnerReady(ctx, attempt: 0, feedback: true);
  }
```

Insert a new method immediately after its closing `}` (before the `/// Static new-thread navigation for screenshot scene S5.` doc comment that follows):

```dart
    ctx.router.navigate(PriorityRoute(priorityIdString: rootPriorityIdString));
    _pushNewThreadWhenInnerReady(ctx, attempt: 0, feedback: true);
  }

  /// Opens the new-thread compose flow in **private-note** mode for
  /// [priorityIdString] — the sidebar's per-focus "Add private note"
  /// shortcut. Mirrors [_openFeedbackThread]: reconfigure an already-live
  /// page via [NewThreadPageState.requestNote], otherwise push a fresh
  /// private-note compose onto the inner stack (polling for the inner
  /// router on cold start). Unlike feedback (always anchored to Inbox), the
  /// cold-start seed priority is the clicked focus itself.
  static void _openPrivateNote(
    BuildContext context,
    String priorityIdString,
  ) {
    final ctx = navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;

    // Reconfigure an already-live (AutoRoute-reused) new-thread page for a
    // private note; a fresh mount instead reacts to the `notePriorityId`
    // route param.
    NewThreadPageState.requestNote(priorityIdString);

    final tabsRouter = _findTabsRouter(ctx.router.root);
    final innerRouter = _findPriorityInnerRouter(ctx.router.root);
    if (tabsRouter != null && innerRouter != null) {
      if (tabsRouter.activeIndex != _kTabActivity) {
        tabsRouter.setActiveIndex(_kTabActivity);
      }
      if (innerRouter.current.name != NewThreadRoute.name) {
        innerRouter.push(NewThreadRoute(notePriorityId: priorityIdString));
      }
      return;
    }

    // Cold-start path: the Activity-tab PriorityRoute isn't mounted yet.
    // Mount it seeded with the clicked focus, then push the private-note
    // compose once the inner router materializes.
    ThreadHeaderNotifier.pendingNewThreadIntent.value = true;
    Future.delayed(const Duration(seconds: 3), () {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    });
    ctx.router.navigate(PriorityRoute(priorityIdString: priorityIdString));
    _pushNewThreadWhenInnerReady(
      ctx,
      attempt: 0,
      notePriorityId: priorityIdString,
    );
  }
```

- [ ] **Step 3: Add the public `openPrivateNote` entry point**

Find `PrioritiesShell.openFeedbackThread` (around line 106-109):

```dart
  static void openFeedbackThread(
    BuildContext context,
    String rootPriorityIdString,
  ) => _PrioritiesShellState._openFeedbackThread(context, rootPriorityIdString);
```

Add immediately after it:

```dart

  /// Opens the new-thread compose flow in private-note mode for
  /// [priorityIdString], driving the Activity-tab inner stack so it works
  /// in single- AND multi-panel. The public entry point for the
  /// [NewPrivateNote] command; delegates to the state's navigation logic
  /// (which doesn't depend on `this`).
  static void openPrivateNote(
    BuildContext context,
    String priorityIdString,
  ) => _PrioritiesShellState._openPrivateNote(context, priorityIdString);
```

- [ ] **Step 4: Analyze**

```bash
cd apps/plot && flutter analyze lib/widget/priorities_shell.dart
```

Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/priorities_shell.dart
git commit -m "feat(app): add PrioritiesShell.openPrivateNote navigation entry point"
```

---

## Task 3: `NewPrivateNote` command

**Files:**
- Modify: `apps/plot/lib/command/priority.dart`
- Test: `apps/plot/test/command/new_private_note_test.dart`

**Interfaces:**
- Consumes: `PrioritiesShell.openPrivateNote(context, priorityIdString)` (Task 2), existing `CommandRoute` / `Command` base classes (`apps/plot/lib/command/base.dart`), existing `Priority` (`apps/plot/lib/store/store.dart`).
- Produces (used by Task 4): `class NewPrivateNote extends Command` with constructor `NewPrivateNote(Priority priority)`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/new_private_note_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/command/priority.dart';
import 'package:plot/store/store.dart';

Priority _priority({required String title}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(title.toLowerCase()),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
    sendWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  testWidgets(
    'NewPrivateNote.run returns OpenPrivateNoteThread for the priority',
    (tester) async {
      final priority = _priority(title: 'Work');
      late BuildContext ctx;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final result = await NewPrivateNote(priority).run(ctx);

      expect(result, isA<OpenPrivateNoteThread>());
      expect(
        (result as OpenPrivateNoteThread).priorityIdString,
        priority.id.toShortString(),
      );
    },
  );
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
cd apps/plot && flutter test test/command/new_private_note_test.dart
```

Expected: FAIL — `NewPrivateNote`/`OpenPrivateNoteThread` are undefined.

- [ ] **Step 3: Implement `NewPrivateNote` and `OpenPrivateNoteThread`**

In `apps/plot/lib/command/priority.dart`, find `ShowPriorityCommands` (around line 1670-1681):

```dart
class ShowPriorityCommands extends ShowCommands {
  ShowPriorityCommands(Priority priority, {bool current = false})
    : super(
        title: 'More',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: current
              ? currentPriorityCommandGroups(priority)
              : priorityCommandGroups(priority),
        ),
      );
}
```

Add immediately after it:

```dart

/// Sidebar shortcut on a focus row's hover state: opens the New Thread
/// compose flow with that focus pre-selected as a private-note target (no
/// roster). See [PrioritiesShell.openPrivateNote].
class NewPrivateNote extends Command {
  NewPrivateNote(this.priority)
    : super(
        title: 'Add private note',
        eventObject: EventObject.activity,
        eventAction: EventAction.opened,
        icon: PlotIcon.note,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return OpenPrivateNoteThread(priority.id.toShortString());
  }
}

/// Navigates to the new-thread compose flow in private-note mode. Overrides
/// [go] to drive the Activity-tab inner stack via
/// [PrioritiesShell.openPrivateNote] instead of a plain `navigate` — see
/// [OpenFeedbackThread] (command/settings.dart) for why a plain
/// `navigate(PriorityRoute(children: [NewThreadRoute(...)]))` is unsafe once
/// PriorityRoute is already mounted. The [PriorityRoute] passed to `super`
/// is only a placeholder so `route` stays non-null; [go] never uses it.
class OpenPrivateNoteThread extends CommandRoute {
  OpenPrivateNoteThread(this.priorityIdString)
    : super(PriorityRoute(priorityIdString: priorityIdString));

  final String priorityIdString;

  @override
  Future<void> go(BuildContext context) async {
    if (!context.mounted) return;
    PrioritiesShell.openPrivateNote(context, priorityIdString);
  }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
cd apps/plot && flutter test test/command/new_private_note_test.dart
```

Expected: PASS.

- [ ] **Step 5: Analyze**

```bash
cd apps/plot && flutter analyze lib/command/priority.dart test/command/new_private_note_test.dart
```

Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/priority.dart apps/plot/test/command/new_private_note_test.dart
git commit -m "feat(app): add NewPrivateNote command"
```

---

## Task 4: Sidebar button

**Files:**
- Modify: `apps/plot/lib/widget/priority.dart`

**Interfaces:**
- Consumes: `NewPrivateNote(Priority priority)` (Task 3), existing `Button.icon(Command command)` (`apps/plot/lib/widget/button.dart:66`).

No automated test — this widget (`PriorityWidget`) is never pumped directly in any existing test (confirmed: no test file references `PriorityWidget(`); the existing `PrioritiesList`/`priorities_list_fyi_test.dart` tests only exercise pure data getters, not the rendered widget tree, and building new pump infrastructure for this row (which needs a live `PriorityBloc`/provider tree) would be disproportionate to a one-line addition that reuses the row's existing, already-working hover mechanism unchanged. Verified manually in Task 5.

- [ ] **Step 1: Add the button before the existing More button**

In `apps/plot/lib/widget/priority.dart`, find the `trailingBuilder` (around line 233-261):

```dart
      trailingBuilder: (isHovered, hasFocus) {
        final hovered = isHovered || hasFocus;
        // Reserve vertical space so the tile height doesn't jump when hover
        // buttons appear. Width collapses to 0 when not hovered so the body
        // gets full width. Roomy mode matches the compose pill row height
        // (gutter + sm padding top & bottom = 36) so a focus row and a
        // NewThreadPage pill are the same height.
        final buttonSlotHeight = widget.roomy
            ? listRowGutter + buildContext.theme.spacing.sm * 2
            : buildContext.theme.iconSizes.base * 2;

        return Padding(
          padding: EdgeInsets.only(right: leadingH),
          child: SizedBox(
            height: buttonSlotHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The resting weekly-total chip is hidden for now — time
                // totals live in the time log. (`_PriorityWeeklyTotal` is
                // kept below so it's easy to re-add here later.) Hover still
                // surfaces the menu; focuses are flat, so there's no
                // "pin to top" affordance.
                if (hovered) Button.icon(ShowPriorityCommands(priority)),
              ],
            ),
          ),
        );
      },
```

Replace the `children` list with:

```dart
      trailingBuilder: (isHovered, hasFocus) {
        final hovered = isHovered || hasFocus;
        // Reserve vertical space so the tile height doesn't jump when hover
        // buttons appear. Width collapses to 0 when not hovered so the body
        // gets full width. Roomy mode matches the compose pill row height
        // (gutter + sm padding top & bottom = 36) so a focus row and a
        // NewThreadPage pill are the same height.
        final buttonSlotHeight = widget.roomy
            ? listRowGutter + buildContext.theme.spacing.sm * 2
            : buildContext.theme.iconSizes.base * 2;

        return Padding(
          padding: EdgeInsets.only(right: leadingH),
          child: SizedBox(
            height: buttonSlotHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The resting weekly-total chip is hidden for now — time
                // totals live in the time log. (`_PriorityWeeklyTotal` is
                // kept below so it's easy to re-add here later.) Hover still
                // surfaces the menu; focuses are flat, so there's no
                // "pin to top" affordance.
                if (hovered) Button.icon(NewPrivateNote(priority)),
                if (hovered) Button.icon(ShowPriorityCommands(priority)),
              ],
            ),
          ),
        );
      },
```

(`NewPrivateNote` is already in scope — `widget/priority.dart` imports `package:plot/command/command.dart`, which exports `command/priority.dart`.)

- [ ] **Step 2: Analyze**

```bash
cd apps/plot && flutter analyze lib/widget/priority.dart
```

Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/priority.dart
git commit -m "feat(app): show private-note shortcut on hovered sidebar focus rows"
```

---

## Task 5: Manual verification and docs

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)

- [ ] **Step 1: Full analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: `No issues found!`

- [ ] **Step 2: Run the full test suite**

```bash
cd apps/plot && flutter test
```

Expected: all tests pass (including the new `test/command/new_private_note_test.dart`).

- [ ] **Step 3: Manual verification via the `run-app` skill**

Invoke the `run-app` skill to launch Plot.app, then verify:

1. Hover a focus row in the sidebar (not the "Everything" entry). The new note icon appears immediately to the left of the "⋯" More button; hovering off hides both.
2. Click the note icon on a focus **other than** the one currently open. The New Thread compose page opens directly (no step-1 picker), addressed as a private note to that focus, no recipients, note editor focused.
3. While already mid-compose with a recipient selected (any target), click the note icon on a different focus row. The compose page reconfigures to a private note for that focus (recipient cleared) instead of opening a second page.
4. From a cold start (or a tab where the Activity stack isn't mounted, e.g. the Agenda tab on a phone-width layout), click the note icon on a focus row. The app switches to the Activity tab and lands on the private-note compose for that focus.
5. Confirm the sidebar's currently-highlighted/selected focus does not change as a side effect of steps 2-4 (composing is Activity-tab-scoped, not tied to the sidebar selection).

If any of these fail, fix before proceeding — do not report this task complete without having exercised the flow in the running app (per `apps/plot/AGENTS.md`: UI changes must be verified in the app, not just via `flutter analyze`/tests).

- [ ] **Step 4: Add the user-facing changelog fragment**

```bash
pnpm updates:new "Add a private-note shortcut to sidebar focuses"
```

Expected output: `Created docs/updates.d/add-a-private-note-shortcut-to-sidebar-focuses-<id>.md — edit it with your update bullet(s).`

Edit the created file to:

```markdown
### Focuses

- You can now start a private note for a focus straight from the sidebar — hover over it and click the note icon.
```

- [ ] **Step 5: Commit**

```bash
git add docs/updates.d/
git commit -m "docs: add changelog fragment for sidebar private-note shortcut"
```

---

## Self-Review Notes

- **Spec coverage:** button placement/visibility (Task 4), icon/tooltip (Task 3), navigation behavior including compose-in-progress replacement and no sidebar-selection side effect (Tasks 1-2, verified Task 5), scope exclusion of "Everything" (Task 4 only touches `PriorityWidget`, not `FixedFocusTile` — no change needed there, so no task references it), testing (Tasks 3 and 5), out-of-scope items (no task touches `FixedFocusTile` or the manual picker section) — all spec sections are covered.
- **Placeholder scan:** no TBD/TODO; every step has complete code or an exact command with expected output.
- **Type consistency:** `priorityIdString` (String) is the type threaded through `NewThreadPageState.requestNote`, `NewThreadRoute(notePriorityId:)`, `PrioritiesShell.openPrivateNote`, `NewPrivateNote.run()` → `OpenPrivateNoteThread(priorityIdString)` consistently — no `Uuid`/`String` mismatches. `NewPrivateNote(Priority priority)` and `Button.icon(NewPrivateNote(priority))` agree on the constructor shape used in Task 4.
