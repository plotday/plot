# Last-used connection default on NewThreadPage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When opening `NewThreadPage`, default the connection compose chip to the user's last-used connection (per-priority, falling back to global), remembering every choice — Plot thread, twist chat, or connector target.

**Architecture:** Finish wiring the already-built `connectionMru` in `LocalPreferencesBloc`. (1) Record *every* submitted connection choice from `NewThreadPage` under its canonical key (fixing a DM-type key mismatch and the Plot-thread/twist gap), removing the partial recorder in the `AddThreadWithNote` command. (2) On open, seed the default from a new `lastUsedConnectionKey()` selector that reuses the existing priority-then-global ranking.

**Tech Stack:** Flutter / Dart, `flutter_bloc` (Cubit), Drift store models, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-05-29-last-used-connection-default-design.md`

---

## Before you start

- **Branch/worktree.** Do this work on a dedicated branch off `main` (preferably a git worktree — see `superpowers:using-git-worktrees`). The current `theme/section-header-background` branch carries unrelated agenda/theme changes; do not build on top of it.
- **Commit the spec.** As the first commit on the new branch, add the already-written spec:
  ```bash
  git add docs/superpowers/specs/2026-05-29-last-used-connection-default-design.md \
          docs/superpowers/plans/2026-05-29-last-used-connection-default.md
  git commit -m "docs(compose): spec + plan for last-used connection default

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```
- **Generated files.** If `flutter test` complains about missing `*.g.dart` (fresh worktree), run `dart run build_runner build --delete-conflicting-outputs` in `apps/plot` first.
- **All commands run from `apps/plot/`** unless noted.

---

## File Structure

- `apps/plot/lib/widget/connection_targets.dart` — **modify.** Owns `CreateTarget`. Add the shared `connectionTargetKey(...)` builder + `createLinkActionKey(CreateLinkUserAction)`, and refactor `CreateTarget.key` to delegate to the builder so a key recorded from a draft action always matches the picker's `CreateTarget.key`.
- `apps/plot/lib/state/local_preferences.dart` — **modify.** Add `lastUsedConnectionKey({candidateKeys, priorityId})` to `LocalPreferencesBloc`.
- `apps/plot/lib/page/new_thread.dart` — **modify.** Record the chosen connection on submit (`_onChatSubmitted` + new `_currentConnectionKey()`); seed the default on open (`_initializeDraft` + new `_applyLastUsedConnectionDefault()`); add a `recordUsage` flag to `_selectTwist`.
- `apps/plot/lib/command/thread.dart` — **modify.** Remove the partial connector-only recorder in `AddThreadWithNote` and its now-unused local + import.
- `apps/plot/test/widget/connection_targets_test.dart` — **create.** Unit tests for `createLinkActionKey`.
- `apps/plot/test/state/local_preferences_test.dart` — **modify.** Add `lastUsedConnectionKey` tests.
- `docs/updates.md` — **modify.** One user-facing bullet.

---

## Task 1: Canonical connection-key helper

Add one source of truth for the connection identity/MRU key, shared by `CreateTarget.key` (producer) and a new `createLinkActionKey` (consumer that reads it back off a draft's `CreateLinkUserAction`). This fixes the DM-type mismatch where the action key was `tw|null|linkType` but the target key was `tw||linkType|targets`.

**Files:**
- Test: `apps/plot/test/widget/connection_targets_test.dart` (create)
- Modify: `apps/plot/lib/widget/connection_targets.dart` (add helpers ~after line 93; refactor `key` getter at lines 43-45)

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/widget/connection_targets_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart' show CreateLinkUserAction;
import 'package:plot/widget/connection_targets.dart' show createLinkActionKey;

void main() {
  group('createLinkActionKey', () {
    test('channel-type form is twist|channel|linkType', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw1',
        channelId: 'ch1',
        linkType: 'thread',
        status: 'open',
        connectorName: 'Slack',
        linkTypeLabel: 'Message',
        channelName: 'general',
        dmTargets: 'channels',
      );
      expect(createLinkActionKey(action), 'tw1|ch1|thread');
    });

    test('DM-type form is twist||linkType|targets (no |null|)', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw1',
        channelId: null,
        linkType: 'dm',
        status: 'open',
        connectorName: 'Slack',
        linkTypeLabel: 'Direct message',
        channelName: 'Slack: Acme',
        dmTargets: 'contacts',
      );
      expect(createLinkActionKey(action), 'tw1||dm|contacts');
    });

    test('addresses-type is treated as DM form', () {
      const action = CreateLinkUserAction(
        twistInstanceId: 'tw2',
        channelId: null,
        linkType: 'email',
        status: 'open',
        connectorName: 'Gmail',
        linkTypeLabel: 'Email',
        channelName: 'Gmail',
        dmTargets: 'addresses',
      );
      expect(createLinkActionKey(action), 'tw2||email|addresses');
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/widget/connection_targets_test.dart`
Expected: FAIL — compile error, `createLinkActionKey` is undefined.

- [ ] **Step 3: Add the shared builder + `createLinkActionKey`**

In `apps/plot/lib/widget/connection_targets.dart`, add these top-level functions immediately after the `CreateTarget` class closes (after line 93, before `loadCreateTargets`). `CreateLinkUserAction` is already in scope via the `package:plot/store/store.dart` import at line 4.

```dart
/// Canonical identity/MRU key for a connection target. Shared by
/// [CreateTarget.key] and [createLinkActionKey] so a key recorded from a
/// draft's [CreateLinkUserAction] always matches the [CreateTarget] the
/// picker built — including DM-type targets (`contacts`/`addresses`), whose
/// key uses the `twist||linkType|targets` form rather than `twist|null|...`.
String connectionTargetKey({
  required String twistInstanceId,
  required String? channelId,
  required String linkType,
  required String? dmTargets,
}) {
  final isDm = dmTargets == 'contacts' || dmTargets == 'addresses';
  return isDm
      ? '$twistInstanceId||$linkType|$dmTargets'
      : '$twistInstanceId|$channelId|$linkType';
}

/// The [connectionTargetKey] for the connection a [CreateLinkUserAction]
/// targets. Used to record connection usage from a submitted draft so the
/// MRU keys line up with the [CreateTarget]s loaded for the picker.
String createLinkActionKey(CreateLinkUserAction action) => connectionTargetKey(
      twistInstanceId: action.twistInstanceId,
      channelId: action.channelId,
      linkType: action.linkType,
      dmTargets: action.dmTargets,
    );
```

- [ ] **Step 4: Refactor `CreateTarget.key` to delegate to the shared builder**

In the same file, replace the existing getter (lines 43-45):

```dart
  /// Stable identity for MRU keying and de-duping.
  String get key => isDmType
      ? '${twist.id}||${linkType.type}|${compose.targets}'
      : '${twist.id}|${channel!.channelId}|${linkType.type}';
```

with:

```dart
  /// Stable identity for MRU keying and de-duping. Delegates to
  /// [connectionTargetKey] so it stays byte-identical to the key recorded
  /// from a draft's [CreateLinkUserAction] (see [createLinkActionKey]).
  String get key => connectionTargetKey(
        twistInstanceId: twist.id.toString(),
        channelId: channel?.channelId,
        linkType: linkType.type,
        dmTargets: compose.targets,
      );
```

(Output is unchanged: for DM targets `compose.targets` is `contacts`/`addresses` → `twist||linkType|targets`; for channel targets it falls to `twist|channelId|linkType`.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/widget/connection_targets_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Analyze**

Run: `flutter analyze lib/widget/connection_targets.dart test/widget/connection_targets_test.dart`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add lib/widget/connection_targets.dart test/widget/connection_targets_test.dart
git commit -m "flutter(compose): share canonical connection key, fix DM-type mismatch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `lastUsedConnectionKey` selector on LocalPreferencesBloc

Add the read side: given the connection keys currently available, return the highest-ranked one that has a recorded use, or `null` when none does (so callers keep their existing default).

**Files:**
- Test: `apps/plot/test/state/local_preferences_test.dart:13-72` (add a new group)
- Modify: `apps/plot/lib/state/local_preferences.dart` (add method after `rankConnectionsByMru`, ~line 101)

- [ ] **Step 1: Write the failing tests**

In `apps/plot/test/state/local_preferences_test.dart`, add this group inside `main()` (after the existing `'LocalPreferencesBloc connection MRU'` group, before the final closing brace at line 72-73). The `setUp` at the top of the file already initializes `ProfilePreferences`.

```dart
  group('lastUsedConnectionKey', () {
    test('prefers a use in the current priority over a more-recent global use',
        () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      // 'A' used in p1; later 'B' used elsewhere (more recent globally).
      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pX');

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'B', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, 'A');
    });

    test('falls back to the global most-recent when this priority has none',
        () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'pX');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pY');

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'B'],
        priorityId: 'p1',
      );
      expect(key, 'B');
    });

    test('returns null when no candidate has a recorded use', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, isNull);
    });

    test('returns plot:thread when that was the last choice', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(
        channelKey: 'plot:thread',
        priorityId: 'p1',
      );

      final key = bloc.lastUsedConnectionKey(
        candidateKeys: ['A', 'plot:thread'],
        priorityId: 'p1',
      );
      expect(key, 'plot:thread');
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/state/local_preferences_test.dart`
Expected: FAIL — compile error, `lastUsedConnectionKey` is not defined on `LocalPreferencesBloc`.

- [ ] **Step 3: Implement the method**

In `apps/plot/lib/state/local_preferences.dart`, add this method to `LocalPreferencesBloc` immediately after `rankConnectionsByMru` (after line 101, the closing `}` of that method):

```dart
  /// The highest-ranked connection key among [candidateKeys] that has a
  /// recorded use, biased per [rankConnectionsByMru] (priority-bucket beats
  /// global-bucket). Returns null when none of the candidates has ever been
  /// used, so callers can keep their existing default (e.g. "Plot thread").
  String? lastUsedConnectionKey({
    required List<String> candidateKeys,
    required String priorityId,
  }) {
    final ranked = rankConnectionsByMru(
      keys: candidateKeys,
      priorityId: priorityId,
    );
    if (ranked.isEmpty) return null;
    final top = ranked.first;
    // Unseen keys sort last, so a seen first key means at least one candidate
    // has history. Guard explicitly in case every candidate is unseen.
    return state.connectionMru.containsKey(top) ? top : null;
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/state/local_preferences_test.dart`
Expected: PASS (existing 4 + new 4 = 8 tests).

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/state/local_preferences.dart test/state/local_preferences_test.dart`
Expected: No issues.

- [ ] **Step 6: Commit**

```bash
git add lib/state/local_preferences.dart test/state/local_preferences_test.dart
git commit -m "flutter(compose): add lastUsedConnectionKey selector to prefs MRU

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Record every submitted choice; remove the partial command recorder

Make `NewThreadPage` the single recording point so Plot threads and twists are remembered too, using the canonical key. Remove the connector-only recorder (and the DM-key bug) from `AddThreadWithNote`.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart` (`_onChatSubmitted` at lines 756-764; add `_currentConnectionKey()`)
- Modify: `apps/plot/lib/command/thread.dart` (remove lines 456, 458-460, 469-479; remove import line 18)

> No new unit test: this is widget-state wiring. The key-derivation logic it relies on is covered by Tasks 1-2; behavior is verified manually in Task 5.

- [ ] **Step 1: Add `_currentConnectionKey()` to `NewThreadPageState`**

In `apps/plot/lib/page/new_thread.dart`, add this method just above `_onChatSubmitted` (before line 756). `createLinkActionKey` and `ConnectionChoice` are available via the `package:plot/widget/widget.dart` barrel (line 8); `_activeCreateAction` already exists at line 529.

```dart
  /// The canonical connection key for whatever the compose surface currently
  /// has selected: the selected twist, an attached create-link action, or the
  /// "Plot thread" sentinel. Recorded on submit so the next new thread in this
  /// priority defaults back to it (see [_applyLastUsedConnectionDefault]).
  String _currentConnectionKey() {
    if (_selectedTwist != null) return 'twist:${_selectedTwist!.id}';
    final action = _activeCreateAction;
    if (action != null) return createLinkActionKey(action);
    return ConnectionChoice.plotThread.key;
  }
```

- [ ] **Step 2: Record the connection in `_onChatSubmitted`**

Replace the existing method (lines 756-764):

```dart
  void _onChatSubmitted() {
    if (_selectedTwist != null) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        _selectedTwist!.id.toString(),
      );
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }
```

with:

```dart
  void _onChatSubmitted() {
    final prefs = context.read<LocalPreferencesBloc>();
    if (_selectedTwist != null) {
      prefs.recordMentionUsage(_selectedTwist!.id.toString());
    }
    // Remember this connection so the next new thread in this priority
    // defaults to it (see _applyLastUsedConnectionDefault). Fire-and-forget:
    // the route flip to ThreadRoute follows immediately.
    final bloc = _priorityBloc;
    if (bloc != null) {
      unawaited(
        prefs
            .recordConnectionUsage(
              channelKey: _currentConnectionKey(),
              priorityId: bloc.state.draft.priority.id.toString(),
            )
            .catchError((Object e, StackTrace s) {
              Tracker.captureException(e, s);
            }),
      );
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }
```

(`unawaited` is imported at line 1; `Tracker` at line 25.)

- [ ] **Step 3: Remove the recorder from `AddThreadWithNote`**

In `apps/plot/lib/command/thread.dart`, the `run` method currently reads (lines 454-479):

```dart
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final prefsBloc = context.read<LocalPreferencesBloc>();

    final createAction = _data.note?.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;

    // Persist the thread + first note before navigating. Running these in
    // parallel with the route flip let a late `_saveDraft` from the
    // disposing NewThreadPage NoteEditor flip the just-published note row
    // back to draft=true, which the sync push filter excludes — the note
    // would then never reach the server.
    final savedThread = await priorityBloc.add(_data.thread, note: _data.note);

    if (createAction != null) {
      try {
        await prefsBloc.recordConnectionUsage(
          channelKey:
              '${createAction.twistInstanceId}|${createAction.channelId}|${createAction.linkType}',
          priorityId: savedThread.priority.id.toString(),
        );
      } catch (e, st) {
        Tracker.captureException(e, st);
      }
    }

    if (!navigate) {
```

Replace that span with (drops `prefsBloc`, `createAction`, and the recorder block):

```dart
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();

    // Persist the thread + first note before navigating. Running these in
    // parallel with the route flip let a late `_saveDraft` from the
    // disposing NewThreadPage NoteEditor flip the just-published note row
    // back to draft=true, which the sync push filter excludes — the note
    // would then never reach the server.
    final savedThread = await priorityBloc.add(_data.thread, note: _data.note);

    if (!navigate) {
```

- [ ] **Step 4: Remove the now-unused import**

In `apps/plot/lib/command/thread.dart`, delete line 18:

```dart
import 'package:plot/state/local_preferences.dart';
```

(`CreateLinkUserAction` comes from the store barrel used elsewhere — do not touch that import. `Tracker` is still used at other lines — keep it.)

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/page/new_thread.dart lib/command/thread.dart`
Expected: No issues. (If "unused import" or "unused local" appears, it points at something missed in Steps 3-4 — fix it.)

- [ ] **Step 6: Commit**

```bash
git add lib/page/new_thread.dart lib/command/thread.dart
git commit -m "flutter(new-thread): record every connection choice on submit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Seed the last-used connection on open

Pre-select the remembered connection on a fresh draft. No-op for no-history, for share-intent captures, and when a connection is already set.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart` (`_selectTwist` at lines 672-681; `_initializeDraft` at lines 136-149; add `_applyLastUsedConnectionDefault()`)

- [ ] **Step 1: Add a `recordUsage` flag to `_selectTwist`**

An auto-selected default must not reorder the mention MRU. Replace `_selectTwist` (lines 672-681):

```dart
  void _selectTwist(TwistInstance twist) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
    context.read<LocalPreferencesBloc>().recordMentionUsage(
      twist.id.toString(),
    );
  }
```

with:

```dart
  void _selectTwist(TwistInstance twist, {bool recordUsage = true}) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
    // Skipped when selecting a remembered default — a default must not feed
    // back into the mention ranking.
    if (recordUsage) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        twist.id.toString(),
      );
    }
  }
```

(Existing callers — `_applyConnectionChoice` line 458 and `onTwistSelected: _selectTwist` in `build` — keep the default `recordUsage: true`. No changes needed there.)

- [ ] **Step 2: Add `_applyLastUsedConnectionDefault()`**

Add this method to `NewThreadPageState` (place it just after `_initializeDraft`, after line 149). All referenced symbols are already in scope: `ConnectionChoice`/`PlotThreadChoice` and `ConnectionChoice.target`/`.plotThread` via the widget barrel; `_allConnectionTargets` (line 76); `_activeCreateAction` (line 529); `_applyConnectionChoice` (line 443).

```dart
  /// Pre-selects the user's last-used connection on a fresh draft so the
  /// compose chip defaults to it instead of "Plot thread". No-op when there's
  /// no recorded history (keeps the Plot-thread default), when a connection is
  /// already set, or for share-intent captures (a stray Enter must not post
  /// the shared link to an external connector).
  Future<void> _applyLastUsedConnectionDefault() async {
    if (widget.sharedUrl != null) return;
    final bloc = _priorityBloc;
    if (bloc == null) return;
    if (_selectedTwist != null || _activeCreateAction != null) return;

    final prefs = context.read<LocalPreferencesBloc>();
    final draft = bloc.state.draft;

    // Chat-eligible twists — same filter the connection picker uses.
    final chatTwists = bloc.state.twists
        .where((t) => !t.isSource && (t.threadType?.isNotEmpty ?? false))
        .toList();

    final candidateKeys = <String>[
      ConnectionChoice.plotThread.key,
      ...chatTwists.map((t) => 'twist:${t.id}'),
      ..._allConnectionTargets.map((t) => t.key),
    ];

    final key = prefs.lastUsedConnectionKey(
      candidateKeys: candidateKeys,
      priorityId: draft.priority.id.toString(),
    );
    // Null (no history) or the Plot-thread sentinel → keep the existing
    // default; nothing to apply.
    if (key == null || key == ConnectionChoice.plotThread.key) return;

    if (key.startsWith('twist:')) {
      final twist =
          chatTwists.where((t) => 'twist:${t.id}' == key).firstOrNull;
      if (twist != null) _selectTwist(twist, recordUsage: false);
      return;
    }

    final target =
        _allConnectionTargets.where((t) => t.key == key).firstOrNull;
    if (target != null) {
      await _applyConnectionChoice(ConnectionChoice.target(target));
    }
  }
```

- [ ] **Step 3: Call it from `_initializeDraft`**

Replace `_initializeDraft` (lines 136-149):

```dart
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;

    // Auto-organize is ON by default only in the root ("Everything") priority
    // context and when the user has not explicitly picked or carried over a
    // priority. In a non-root context, the default is the most recent picker
    // priority (session-remembered) or the current context priority — never
    // auto — so the thread goes where the user is working.
    _applyDefaultAutoFile();

    // Load available connection create-targets for the connection chip row.
    await _loadConnections();
  }
```

with:

```dart
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;

    // Auto-organize is ON by default only in the root ("Everything") priority
    // context and when the user has not explicitly picked or carried over a
    // priority. In a non-root context, the default is the most recent picker
    // priority (session-remembered) or the current context priority — never
    // auto — so the thread goes where the user is working.
    _applyDefaultAutoFile();

    // Load available connection create-targets for the connection chip row.
    await _loadConnections();
    if (!mounted) return;

    // Default the connection chip to the user's last-used connection for this
    // priority (falls back to global; no-op with no history).
    await _applyLastUsedConnectionDefault();
  }
```

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/page/new_thread.dart`
Expected: No issues.

- [ ] **Step 5: Commit**

```bash
git add lib/page/new_thread.dart
git commit -m "flutter(new-thread): default connection chip to last-used

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Verify end-to-end + docs

- [ ] **Step 1: Run the full test + analyze for changed areas**

Run:
```bash
flutter test test/state/local_preferences_test.dart test/widget/connection_targets_test.dart
flutter analyze lib/widget/connection_targets.dart lib/state/local_preferences.dart lib/page/new_thread.dart lib/command/thread.dart test/state/local_preferences_test.dart test/widget/connection_targets_test.dart
```
Expected: All tests PASS; analyze reports no issues.

- [ ] **Step 2: Manual smoke test (run-app skill)**

Use the `run-app` skill to launch Plot.app, then verify in a priority that has at least one connector (e.g. Slack) enabled:
1. Open a new thread, switch the connection chip to a Slack channel, type something, submit.
2. Open a new thread again **in the same priority** → the connection chip defaults to that Slack channel (not "Plot thread").
3. Switch the chip back to "Plot thread", submit. Open a new thread again → defaults back to "Plot thread".
4. Open a new thread in a *different* priority that you've never used a connector in → defaults to "Plot thread" (or that priority's own last-used).
5. Share a URL into Plot (share-intent) → connection chip stays "Plot thread" even if your global last-used is a connector.

Expected: each step matches. If not, debug before proceeding.

- [ ] **Step 3: Add a user-facing update note**

In `docs/updates.md`, add this bullet as the **first** line of the top section (match the existing plain-language, no-jargon style):

```markdown
- New threads now remember your last-used connection. When you open the new-thread page, the connection field defaults to whatever you used last in that priority — a Slack channel, an email, a Plot AI chat, or just a plain Plot thread — instead of always starting on "Plot thread". Sharing a link into Plot still starts as a plain Plot thread so nothing gets posted out by accident.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit -m "docs(updates): note last-used connection default

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Finalize**

Run the `/finalize` checklist (lint clean, backwards-compat, error capture, docs). Then open a PR per `superpowers:finishing-a-development-branch`.

---

## Self-review notes (for the executor)

- **Spec coverage:** Recording-all-choices → Task 3; canonical/DM-key fix → Task 1; per-priority-then-global default → Task 2 + Task 4; share-intent skip → Task 4 Step 2; twist-without-mention-MRU → Task 4 Step 1; no-history fallback → Task 2 (returns null) + Task 4 (early return). Tests → Tasks 1, 2; manual → Task 5.
- **Key consistency across tasks:** `'twist:${...id}'`, `ConnectionChoice.plotThread.key` (= `'plot:thread'`), and `createLinkActionKey`/`CreateTarget.key` (via `connectionTargetKey`) are used identically on both the recording side (Task 3) and the candidate/seeding side (Task 4). The recorded key always matches a candidate key.
- **Backwards compat:** `connectionMru` shape is unchanged; old recorded connector keys (channel-type) still match. Old DM-type records used a now-unused `tw|null|linkType` form — they simply never match a candidate and are ignored (graceful). No persisted-format migration needed.
