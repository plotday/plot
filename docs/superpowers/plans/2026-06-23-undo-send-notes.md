# Undo Send for Notes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every user-sent note a 5-second "SENDING" undo window (both replies to an existing thread and the first note of a new thread), shown in the note's author/timestamp footer slot, recallable by clicking the button or pressing Esc.

**Architecture:** A global `PendingSend` `ChangeNotifier` singleton holds the single in-flight note (and, for a new thread, the still-`draft` thread) in memory and arms a 5-second timer. Nothing is published or pushed during the window — the note is rendered from memory as an extra row at the bottom of the thread view with a `SENDING ✕` footer. When the timer fires (or the app closes / signs out), `commit()` saves the note (`draft=false`, pushes) and promotes the new thread; `undo()` drops the in-memory note and restores its content into the NoteEditor. Because nothing is persisted as published during the window, there is no early-push risk and undo needs no cleanup.

**Tech Stack:** Flutter, `flutter_bloc`, `forui` widgets, Drift (local SQLite), `equatable`.

## Global Constraints

- **No Drift schema change.** This feature persists no new columns; do **not** add a migration, do **not** bump `Store.schemaVersion`, do **not** run `build_runner`. (If a step seems to need a new column, it is wrong — re-read the architecture.)
- **forui only.** Import only `package:flutter/widgets.dart` and `package:forui/forui.dart` (never `package:flutter/material.dart`). Use the project `Button`/`FButton` idioms already in `lib/widget/`.
- **Desktop cursor.** The `SENDING ✕` control is a button, not a link — keep the default arrow cursor. Do **not** add `SystemMouseCursors.click`/`MouseRegion`.
- **UI text is sentence case** — except the literal label **`SENDING`**, which the spec specifies verbatim (a stylized status label, like a badge). Use `SENDING` exactly.
- **Bloc only in pages/commands, not widgets.** `PendingSend` is app-global state (not a Bloc); widgets read it via `ListenableBuilder`. Commit/undo logic that needs the store lives in `PendingSend` (store-level, context-free) so it works on app-close/sign-out.
- **Error capture.** Any new `catch` for an unexpected error calls `Tracker.captureException(error, stackTrace)`.
- **Lint gate.** `cd apps/plot && flutter analyze` must pass with no new errors before each commit.
- **Test command.** `cd apps/plot && flutter test <path>`.
- **One in flight at a time.** Submitting a new note while one is pending commits the prior one first (`PendingSend.start` calls `commit()` internally).
- **Scope:** new replies and new-thread first notes only. The *edit-existing-note* path (`_onNoteSubmitted` → `editingNote != null` branch in `note_editor.dart`) is unchanged.

---

## File Structure

| File | Responsibility | Action |
| --- | --- | --- |
| `lib/state/pending_send.dart` | The `PendingSend` singleton: holds in-flight note/thread, 5s timer, `start`/`commit`/`undo`/`flush`. | **Create** |
| `test/state/pending_send_test.dart` | Unit + store-backed tests for the controller. | **Create** |
| `lib/state/thread.dart` | Add `ThreadBloc.sendWithUndo(note)` (defer publish; mentions→contacts merge; emit fresh draft) and `ThreadBloc.restoreDraft(note)`. | **Modify** |
| `lib/command/note.dart` | Route `AddNote.run` through `sendWithUndo`. | **Modify** |
| `lib/state/priority.dart` | Extract `PriorityBloc.resetDraftAfterSend(priority)` from `add()`. | **Modify** |
| `lib/command/thread.dart` | `AddThreadWithNote.run`: keep the new thread `draft`, register the pending send, navigate to the draft thread. | **Modify** |
| `lib/widget/note.dart` | `NoteWidget` gains `sending`/`onUndoSend`; footer renders `SENDING ✕`. | **Modify** |
| `lib/page/thread.dart` | Render `_PendingSendRow` between the list and the composer; Esc-to-undo. | **Modify** |
| `lib/widget/window.dart` | Flush pending send during shutdown. | **Modify** |
| `lib/base.dart` | Flush pending send at start of `signOut`. | **Modify** |
| `test/widget/note_sending_footer_test.dart` | Widget test for the `SENDING ✕` footer. | **Create** |
| `docs/updates.md`, `docs/features.md` | User-facing changelog + feature note. | **Modify** |

---

## Task 1: `PendingSend` controller

**Files:**
- Create: `apps/plot/lib/state/pending_send.dart`
- Test: `apps/plot/test/state/pending_send_test.dart`

**Interfaces:**
- Produces:
  - `class PendingSend extends ChangeNotifier`
  - `static final PendingSend instance`
  - `bool get isPending`
  - `Note? get pendingNote`
  - `ThreadId? get pendingThreadId` (== `pendingNote?.threadId`)
  - `void start({required Note note, Thread? newThread})` — `note` is the **publish version** (`draft == false`); `newThread` is the **promote version** (`draft == false`) for a new thread, else null.
  - `Future<void> commit()` — saves thread (if any) then note (`pushToRemote: true`); clears.
  - `Future<Note?> undo()` — clears and returns the note for restore; no DB writes.
  - `Future<void> flush()` — `if (isPending) await commit();` (for app-close / sign-out).
  - `static const Duration window = Duration(seconds: 5)`

- [ ] **Step 1: Write failing state-machine tests**

Create `apps/plot/test/state/pending_send_test.dart`:

```dart
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/store/store.dart';

final _self = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _threadId = ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

Note _publishNote({String content = 'hello'}) => Note(
  id: NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd'),
  threadId: _threadId,
  authorId: _self,
  draft: false,
  content: content,
  createdAt: DateTime(2026),
  sourceCreatedAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    // Always leave the singleton idle for the next test.
    await PendingSend.instance.undo();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('start makes it pending and exposes the note', () {
    PendingSend.instance.start(note: _publishNote());
    expect(PendingSend.instance.isPending, isTrue);
    expect(PendingSend.instance.pendingNote?.content, 'hello');
    expect(PendingSend.instance.pendingThreadId, _threadId);
  });

  test('undo clears state and returns the note (no DB write)', () async {
    PendingSend.instance.start(note: _publishNote());
    final returned = await PendingSend.instance.undo();
    expect(returned?.content, 'hello');
    expect(PendingSend.instance.isPending, isFalse);
    final rows = await store.notes.select().get();
    expect(rows, isEmpty); // nothing was persisted during the window
  });

  test('timer fires commit after the 5s window', () {
    fakeAsync((async) {
      PendingSend.instance.start(note: _publishNote());
      expect(PendingSend.instance.isPending, isTrue);
      async.elapse(const Duration(seconds: 5));
      expect(PendingSend.instance.isPending, isFalse);
    });
  });

  test('start commits a prior pending send (one at a time)', () async {
    PendingSend.instance.start(note: _publishNote(content: 'first'));
    PendingSend.instance.start(note: _publishNote(content: 'second'));
    // The first was committed; only the second is pending.
    expect(PendingSend.instance.pendingNote?.content, 'second');
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/plot && flutter test test/state/pending_send_test.dart`
Expected: FAIL — `pending_send.dart` does not exist / `PendingSend` undefined.

- [ ] **Step 3: Implement `PendingSend`**

Create `apps/plot/lib/state/pending_send.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:plot/store/store.dart';

/// Global, single-slot "undo send" controller.
///
/// When a user sends a note we do NOT publish/push it immediately. Instead the
/// publish-ready note (and, for a brand-new thread, the promote-ready thread)
/// is held here in memory and a [window] timer is armed. The thread view
/// renders the held note with a `SENDING` footer. When the timer fires — or the
/// app closes / signs out — [commit] saves and pushes it. [undo] drops it and
/// hands the note back so its content can be restored into the editor.
///
/// Only one send is ever in flight: [start] commits any prior pending send
/// first.
class PendingSend extends ChangeNotifier {
  PendingSend._();
  static final PendingSend instance = PendingSend._();

  static const Duration window = Duration(seconds: 5);

  Note? _note;
  Thread? _newThread;
  Timer? _timer;

  bool get isPending => _note != null;
  Note? get pendingNote => _note;
  ThreadId? get pendingThreadId => _note?.threadId;

  /// Registers a new pending send. [note] must be the publish version
  /// (`draft == false`). [newThread] is the promote version (`draft == false`)
  /// for a new-thread send, or null when replying to an existing thread.
  void start({required Note note, Thread? newThread}) {
    if (isPending) {
      // One at a time: finalize the prior send before starting a new one.
      unawaited(commit());
    }
    _note = note;
    _newThread = newThread;
    _timer?.cancel();
    _timer = Timer(window, () => unawaited(commit()));
    notifyListeners();
  }

  /// Publishes the held note (and promotes the held thread), then clears.
  /// Store-level and context-free so it is safe from app-close / sign-out.
  Future<void> commit() async {
    final note = _note;
    final newThread = _newThread;
    if (note == null) return;
    _clear();
    notifyListeners();
    try {
      if (newThread != null) {
        // draft == false → promotes the thread out of draft and pushes it.
        await newThread.save();
      }
      // draft == false → publishes the note and pushes it.
      await note.save();
    } catch (e, t) {
      // A failed commit must not strand the app; surface for diagnosis.
      Tracker.captureException(e, t);
    }
  }

  /// Cancels the pending send and returns the note so the caller can move its
  /// content back into the NoteEditor. Performs no DB writes — nothing was
  /// persisted as published during the window.
  Future<Note?> undo() async {
    final note = _note;
    _clear();
    notifyListeners();
    return note;
  }

  /// Commit immediately if something is pending (app-close / sign-out).
  Future<void> flush() async {
    if (isPending) await commit();
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _note = null;
    _newThread = null;
  }
}
```

> `Tracker` is exported transitively via `package:plot/store/store.dart` (used throughout the store layer). If `flutter analyze` reports it unresolved, add `import 'package:plot/analytics/tracker.dart';`.

- [ ] **Step 4: Run to verify pass**

Run: `cd apps/plot && flutter test test/state/pending_send_test.dart`
Expected: PASS (4 tests). The `fake_async` package is already a dev dependency (used elsewhere in `test/`); if not, add it: `flutter pub add --dev fake_async`.

- [ ] **Step 5: Add a store-backed commit test**

Append to `test/state/pending_send_test.dart` inside `main()`:

```dart
  test('commit publishes the note locally (draft=false, pending set)', () async {
    PendingSend.instance.start(note: _publishNote());
    await PendingSend.instance.commit();
    final rows = await store.notes.select().get();
    expect(rows, hasLength(1));
    expect(rows.single.draft, isFalse);
    expect(rows.single.pending, isNotNull); // marked for sync
  });
```

Run: `cd apps/plot && flutter test test/state/pending_send_test.dart`
Expected: PASS (5 tests). If `Note.save()`'s unawaited push errors because `SyncOrchestrator.instance` is uninitialized in tests, initialize it in `setUp` the same way the app does (mirror an existing test that calls `.save()`); the local DB write asserted here completes before `save()` returns regardless.

- [ ] **Step 6: Commit**

```bash
cd apps/plot
flutter analyze lib/state/pending_send.dart test/state/pending_send_test.dart
git add lib/state/pending_send.dart test/state/pending_send_test.dart
git commit -m "feat(notes): add PendingSend undo-send controller"
```

---

## Task 2: Defer the existing-thread send (`ThreadBloc.sendWithUndo` + `restoreDraft`)

**Files:**
- Modify: `apps/plot/lib/state/thread.dart` (add two methods near `add()` at line 263)
- Modify: `apps/plot/lib/command/note.dart` (`AddNote.run`, line 54)
- Test: `apps/plot/test/state/thread_send_with_undo_test.dart` (**create**)

**Interfaces:**
- Consumes: `PendingSend.instance.start(note:)` (Task 1).
- Produces:
  - `Future<void> ThreadBloc.sendWithUndo(Note note)` — does the non-publish work of `add()` (mentions→contacts merge, emit fresh draft, clear reply/editing, BCC drop) and registers the pending send **instead of** saving the note.
  - `void ThreadBloc.restoreDraft(Note? note)` — sets the composer draft to the un-sent note's content/actions and restores `replyTo`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/thread_send_with_undo_test.dart`. Model the Store/Injector setup on `test/state/compose_targets_test.dart` (lines 369–438). Construct a `ThreadBloc` over a saved thread, call `sendWithUndo`, and assert the note is **not yet** in the DB but `PendingSend` is pending:

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/state/pending_send.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/store/store.dart';
// ...plus the LocalPreferencesBloc + thread/note construction helpers used by
//    compose_targets_test.dart (copy that file's setUp + _insert* helpers).

void main() {
  // setUp/tearDown identical to compose_targets_test.dart, PLUS:
  //   tearDown(() async { await PendingSend.instance.undo(); });

  test('sendWithUndo registers a pending send and does not publish yet',
      () async {
    // Arrange: a saved (non-draft) thread + a ThreadBloc over it.
    final thread = /* build + save a non-draft Thread, see compose_targets_test */;
    final bloc = ThreadBloc(thread: thread, localPreferences: localPreferences);
    final note = thread // build a publish-ready note for this thread:
        ; // Note(... threadId: thread.id, authorId: self, draft: false, content: 'hi', ...)

    // Act
    await bloc.sendWithUndo(note);

    // Assert: pending, but the published note is not in the DB yet.
    expect(PendingSend.instance.isPending, isTrue);
    final published = await (store.notes.select()
          ..where((n) => n.draft.equals(false)))
        .get();
    expect(published, isEmpty);

    // After the window commits, it lands.
    await PendingSend.instance.commit();
    final after = await (store.notes.select()
          ..where((n) => n.draft.equals(false)))
        .get();
    expect(after, hasLength(1));
    await bloc.close();
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/plot && flutter test test/state/thread_send_with_undo_test.dart`
Expected: FAIL — `sendWithUndo` undefined.

- [ ] **Step 3: Add `sendWithUndo` and `restoreDraft` to `ThreadBloc`**

In `apps/plot/lib/state/thread.dart`, immediately after the existing `add()` method (ends at line 318), add:

```dart
  /// Like [add], but defers the actual publish/push for 5 seconds so the user
  /// can undo. Does everything [add] does EXCEPT saving the note: it merges
  /// note mentions into thread contacts, emits a fresh draft, clears
  /// reply/editing state, drops hidden-role (BCC) contacts, and registers the
  /// publish-ready note with [PendingSend]. The note is published by
  /// PendingSend.commit() when the window elapses (or on app-close/sign-out).
  Future<void> sendWithUndo(Note note) async {
    var currentThread = state.thread;
    final currentLinks = state.links;

    // Merge new non-twist mentions into thread.contacts (mirrors add()).
    if (note.mentions != null && note.mentions!.isNotEmpty) {
      final newContacts = {...currentThread.contacts};
      bool changed = false;
      for (final mention in note.mentions!) {
        if (!mention.isTwist) {
          if (newContacts.add(mention.toUuid())) changed = true;
        }
      }
      if (changed) {
        final updatedThread =
            currentThread.copyWith(contacts: Value(newContacts.toList()));
        await updatedThread.save();
        emit(state.copyWith(thread: updatedThread));
        currentThread = updatedThread;
      }
    }

    // The publish version. PendingSend.commit() will save this (draft=false).
    final publishNote = note.copyWith(draft: false);

    // Reset the composer to a fresh draft and clear reply/editing — same UI
    // reset add() performs so the editor clears immediately on send.
    emit(
      state.copyWith(
        draft: Note.draft(threadId: currentThread.id),
        clearReplyTo: true,
        clearEditingNote: true,
      ),
    );
    _defaultDraftToPrivateIfViewers();

    PendingSend.instance.start(note: publishNote);

    // BCC auto-drop (mirrors add()); runs async.
    _dropHiddenRoleContactsAfterSend(currentThread, currentLinks);
  }

  /// Moves an un-sent (undone) note's content back into the composer. Restores
  /// content + actions and re-enters reply mode if the note was a reply.
  void restoreDraft(Note? note) {
    if (note == null) return;
    final restored = Note.draft(threadId: state.thread.id)
        .copyWith(content: note.content, actions: note.actions);
    Note? replyTarget;
    if (note.reNoteId != null) {
      replyTarget =
          state.notes.where((n) => n.id == note.reNoteId).firstOrNull;
    }
    emit(
      state.copyWith(
        draft: restored,
        replyTo: replyTarget,
        clearReplyTo: replyTarget == null,
      ),
    );
  }
```

Add the import at the top of `thread.dart` (group with the other `package:plot/state/` imports):

```dart
import 'package:plot/state/pending_send.dart';
```

> `Note.copyWith` takes `content` (`String?`) and `actions` (`List<UserAction>?`) positionally-by-name (verified in `lib/store/note.dart:1386`). `Note.draft({required threadId})` is at `lib/store/note.dart:246`. `state.copyWith` supports `draft`, `replyTo`, `clearReplyTo`, `clearEditingNote` (used by `add()` above).

- [ ] **Step 4: Route `AddNote` through `sendWithUndo`**

In `apps/plot/lib/command/note.dart`, change the `run` body (line 54):

```dart
    // Use ThreadBloc.sendWithUndo() (deferred, undoable) when a ThreadBloc is
    // available; otherwise save directly (no undo window outside a thread view).
    if (activityBloc != null) {
      await activityBloc.sendWithUndo(note);
    } else {
      await note.save();
    }
```

- [ ] **Step 5: Run tests + analyze**

Run:
```bash
cd apps/plot
flutter test test/state/thread_send_with_undo_test.dart
flutter analyze lib/state/thread.dart lib/command/note.dart
```
Expected: PASS; analyze clean.

- [ ] **Step 6: Commit**

```bash
git add lib/state/thread.dart lib/command/note.dart test/state/thread_send_with_undo_test.dart
git commit -m "feat(notes): defer existing-thread sends through PendingSend"
```

---

## Task 3: Defer the new-thread send (keep thread draft, navigate, register pending)

**Files:**
- Modify: `apps/plot/lib/state/priority.dart` (extract `resetDraftAfterSend` from `add()`, line 3960–3970)
- Modify: `apps/plot/lib/command/thread.dart` (`AddThreadWithNote.run`, lines 540–570)
- Test: `apps/plot/test/command/add_thread_with_note_undo_test.dart` (**create**, light — see note)

**Interfaces:**
- Consumes: `PendingSend.instance.start(note:, newThread:)`, `PriorityBloc.resetDraftAfterSend(priority)`.
- Produces: a new-thread send that leaves the thread `draft=true` in the DB, registers the promote-ready thread + publish-ready note with `PendingSend`, and navigates to the (draft) thread's `ThreadRoute`. `PendingSend.commit()` promotes + publishes.

- [ ] **Step 1: Extract `resetDraftAfterSend` in `PriorityBloc`**

In `apps/plot/lib/state/priority.dart`, the tail of `add()` (lines 3960–3970) emits a fresh priority draft. Extract it into a reusable method (place it right after `add()`):

```dart
  /// Emits a fresh draft thread + draft note for the priority so the compose
  /// surface is clean for the next new thread. Extracted from [add] so the
  /// deferred (undoable) new-thread path can reuse it without publishing.
  void resetDraftAfterSend(Priority priority) {
    final newDraft = Thread(
      priority: _newThreadDefaultPriority ?? priority,
      draft: true,
    );
    emit(
      state.copyWith(
        draft: newDraft,
        draftNote: Note.draft(threadId: newDraft.id),
      ),
    );
  }
```

Then replace lines 3960–3970 inside `add()` with a call to it:

```dart
    // Create fresh draft for the priority (use remembered default if set)
    resetDraftAfterSend(thread.priority);

    return savedThread;
```

- [ ] **Step 2: Rewrite `AddThreadWithNote.run` to defer**

In `apps/plot/lib/command/thread.dart`, replace the body of `AddThreadWithNote.run` (lines 540–570) with:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final draftThread = _data.thread; // DB row is still draft=true here.
    final note = _data.note;

    // No note (e.g. an empty thread) → nothing to undo; publish immediately.
    if (note == null) {
      final savedThread = await priorityBloc.add(draftThread, note: null);
      if (navigate && context.mounted) {
        priorityBloc.setThread(savedThread);
        NewThreadPageState.requestReset();
        await context.router.replace(
          ThreadRoute(threadIdString: savedThread.id.toShortString()),
        );
      }
      return const CommandDone();
    }

    // One at a time: finalize any prior pending send first.
    await PendingSend.instance.commit();

    // Stash a pending create_link payload keyed by thread id so the thread
    // push (at commit) dispatches to the connector's onCreateLink. Mirrors
    // PriorityBloc.add lines 3920-3937.
    final createAction =
        note.actions?.whereType<CreateLinkUserAction>().firstOrNull;
    if (createAction != null) {
      ThreadsBase.pendingCreateLinks[draftThread.id.toString()] = {
        'create_link': {
          'twist_instance_id': createAction.twistInstanceId,
          'channel_id': createAction.channelId,
          'type': createAction.linkType,
          'status': createAction.status,
        },
        if (note.content != null) 'note_content': note.content,
      };
    }

    // Promote/publish versions captured now (Base.actorId is available here),
    // so PendingSend.commit() stays store-level and context-free.
    final isSelfTodo = note.hasTag(Tag.todo, Base.actorId);
    final promoteThread =
        draftThread.copyWith(draft: false, todo: isSelfTodo ? true : null);
    final publishNote = note.copyWith(threadId: draftThread.id, draft: false);

    // Reset the compose surface for the next thread WITHOUT publishing this one.
    priorityBloc.resetDraftAfterSend(draftThread.priority);

    PendingSend.instance.start(note: publishNote, newThread: promoteThread);

    // Navigate into the (still-draft) thread view — Thread.getOne uses
    // draft:null so a draft thread renders fine; the SENDING note shows via
    // the page's _PendingSendRow.
    if (navigate && context.mounted) {
      priorityBloc.setThread(draftThread);
      NewThreadPageState.requestReset();
      await context.router.replace(
        ThreadRoute(threadIdString: draftThread.id.toShortString()),
      );
    }

    return const CommandDone();
  }
```

Add imports at the top of `apps/plot/lib/command/thread.dart` if not already present:

```dart
import 'package:plot/state/pending_send.dart';
import 'package:plot/store/store.dart' show Base, Tag, ThreadsBase, CreateLinkUserAction;
```

> `note.hasTag(Tag.todo, Base.actorId)` is the same predicate `PriorityBloc.add` uses (priority.dart:3916). `thread.copyWith(draft:, todo:)` is verified (priority.dart:3918). `ThreadsBase.pendingCreateLinks` is the same map used at priority.dart:3928. Match the existing import style in `thread.dart` for the exact symbols (some may already be imported via `widget/widget.dart`/`store.dart`).

- [ ] **Step 3: Light test for the deferral**

A full router/page test is heavy. Write a focused test that drives `PriorityBloc` directly:

Create `apps/plot/test/command/add_thread_with_note_undo_test.dart` that:
1. Sets up Store + PriorityBloc (mirror `test/state/` setup that constructs a `PriorityBloc`; if none exists, assert at the `PendingSend` level instead).
2. Calls `priorityBloc.resetDraftAfterSend(priority)` and asserts `state.draft.draft == true` and a fresh `state.draftNote`.

```dart
test('resetDraftAfterSend emits a fresh draft thread + note', () {
  // Arrange a PriorityBloc with a known priority (see existing priority tests).
  priorityBloc.resetDraftAfterSend(priority);
  expect(priorityBloc.state.draft.draft, isTrue);
  expect(priorityBloc.state.draftNote.threadId, priorityBloc.state.draft.id);
});
```

If the harness has no existing `PriorityBloc` test to copy setup from, skip this file and rely on the Task 1 store-backed `commit` test (which already proves the promote+publish saves) plus the manual verification in Task 8.

- [ ] **Step 4: Analyze + run**

Run:
```bash
cd apps/plot
flutter analyze lib/state/priority.dart lib/command/thread.dart
flutter test test/command/add_thread_with_note_undo_test.dart   # if created
```
Expected: clean; PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/state/priority.dart lib/command/thread.dart test/command/add_thread_with_note_undo_test.dart
git commit -m "feat(notes): defer new-thread sends; keep thread draft during undo window"
```

---

## Task 4: `SENDING ✕` footer in `NoteWidget`

**Files:**
- Modify: `apps/plot/lib/widget/note.dart` (`NoteWidget`, footer at lines 236–347)
- Test: `apps/plot/test/widget/note_sending_footer_test.dart` (**create**)

**Interfaces:**
- Consumes: nothing from earlier tasks (pure widget).
- Produces: `NoteWidget({..., bool sending = false, VoidCallback? onUndoSend})`. When `sending == true`, the 30px footer renders a right-aligned xs ghost button `SENDING ✕` whose `onPress` is `onUndoSend`, and hides the author/timestamp + `NoteCommands`.

- [ ] **Step 1: Write the failing widget test**

Create `apps/plot/test/widget/note_sending_footer_test.dart`. Model the host on `test/widget/note_editor_top_bar_test.dart` (theme + `Provider<ColourSchemeData>` + `FTheme` + `Directionality`). `NoteWidget` reads `context.read<ThreadBloc>()`, so wrap it in a `BlocProvider<ThreadBloc>.value` over a test bloc (construct as in Task 2's test), or a minimal stub bloc that returns an empty `ThreadState`.

```dart
testWidgets('sending note shows SENDING and triggers onUndoSend', (tester) async {
  var undone = false;
  final note = /* a non-draft Note with content 'draft text', see helpers */;
  await tester.pumpWidget(
    host( // theme + ThreadBloc provider wrapper
      NoteWidget(note: note, sending: true, onUndoSend: () => undone = true),
    ),
  );
  expect(find.text('SENDING'), findsOneWidget);
  expect(find.text('draft text'), findsOneWidget); // content still visible
  await tester.tap(find.text('SENDING'));
  expect(undone, isTrue);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/plot && flutter test test/widget/note_sending_footer_test.dart`
Expected: FAIL — `NoteWidget` has no `sending`/`onUndoSend` parameter.

- [ ] **Step 3: Add the params and the footer branch**

In `apps/plot/lib/widget/note.dart`, add the two fields to `NoteWidget` (after `searchHighlight`, line 114):

```dart
  /// When true, this note is in its post-send "SENDING" undo window: the
  /// footer shows a `SENDING ✕` ghost button instead of author/timestamp and
  /// commands, and tapping it calls [onUndoSend].
  final bool sending;
  final VoidCallback? onUndoSend;
```

Add them to the constructor (after `this.initiallyExpanded = false,`, line 103):

```dart
    this.sending = false,
    this.onUndoSend,
```

In `build`, replace the footer `SizedBox(height: 30, child: Stack(...))` (lines 236–347) so that when `widget.sending` it renders only the button:

```dart
          SizedBox(
            height: 30,
            child: widget.sending
                ? Align(
                    alignment: Alignment.centerRight,
                    child: FButton(
                      onPress: widget.onUndoSend,
                      variant: FButtonVariant.ghost,
                      style: ghostSizedStyleDelta(
                        context,
                        textStyle: context.theme.typography.xs,
                      ),
                      mainAxisSize: MainAxisSize.min,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: [
                          const Text('SENDING'),
                          Icon(
                            FontAwesomeIcons.xmark,
                            size: context.theme.iconSizes.xs,
                          ),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      // ... EXISTING author/timestamp Positioned + NoteCommands
                      // Align, UNCHANGED (current lines 242-344) ...
                    ],
                  ),
          ),
```

Add the import for the ghost-button helper at the top of `note.dart` (group with other `package:plot/style/` imports):

```dart
import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
```

> `FButton`, `FButtonVariant.ghost`, `ghostSizedStyleDelta`, `context.theme.typography.xs`, and `context.theme.iconSizes.xs` are the exact idiom used at `note_editor.dart:1340-1359`. `FontAwesomeIcons.xmark` is already used in `note_editor.dart:1368`. `note.dart` already imports forui + font_awesome (it uses `FTooltip`, `Icon`, `FontAwesomeIcons.cloudArrowUp`).

- [ ] **Step 4: Run to verify pass**

Run: `cd apps/plot && flutter test test/widget/note_sending_footer_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot
flutter analyze lib/widget/note.dart test/widget/note_sending_footer_test.dart
git add lib/widget/note.dart test/widget/note_sending_footer_test.dart
git commit -m "feat(notes): SENDING undo footer on NoteWidget"
```

---

## Task 5: Render the pending row + Esc-to-undo in the thread page

**Files:**
- Modify: `apps/plot/lib/page/thread.dart` (composer area ~749–772; Esc handler 668–680)

**Interfaces:**
- Consumes: `PendingSend.instance` (Task 1), `NoteWidget(sending:, onUndoSend:)` (Task 4), `ThreadBloc.restoreDraft` (Task 2).
- Produces: a `_PendingSendRow` between the note list and the `NoteEditor` that shows the in-flight note for THIS thread; Esc undoes a pending send for this thread before any other Esc behavior.

- [ ] **Step 1: Add `_PendingSendRow` and insert it above the composer**

In `apps/plot/lib/page/thread.dart`, wrap the existing composer `NoteEditor` block (lines 749–772) so a `_PendingSendRow` sits directly above it. Find the `ConstrainedBox(... child: ... NoteEditor(...))` and put both into a `Column`:

```dart
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    _PendingSendRow(threadId: state.thread.id),
    ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: panelConstraints.maxHeight * 0.4,
      ),
      child: Padding(
        // ... existing padding ...
        child: NoteEditor(
          key: _noteEditorKey,
          draft: state.draft,
          flushToBottom: !layoutStateForPanels.multiPanel,
          viewerMode: state.thread.isReadOnly,
        ),
      ),
    ),
  ],
)
```

Add the `_PendingSendRow` widget at the bottom of `thread.dart` (private widget):

```dart
/// Renders the single in-flight "SENDING" note for [threadId] just above the
/// composer (the reversed list puts newest notes here, so the sending note
/// reads as the newest item). Listens to [PendingSend] so it appears/clears
/// reactively. Tapping `SENDING ✕` undoes the send and restores the content.
class _PendingSendRow extends StatelessWidget {
  const _PendingSendRow({required this.threadId});

  final ThreadId threadId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PendingSend.instance,
      builder: (context, _) {
        final pending = PendingSend.instance;
        if (!pending.isPending || pending.pendingThreadId != threadId) {
          return const SizedBox.shrink();
        }
        return NoteWidget(
          note: pending.pendingNote!,
          showAuthor: false,
          sending: true,
          onUndoSend: () async {
            final note = await PendingSend.instance.undo();
            if (!context.mounted) return;
            context.read<ThreadBloc>().restoreDraft(note);
            _noteEditorFocus(context);
          },
        );
      },
    );
  }
}

void _noteEditorFocus(BuildContext context) {
  // Best-effort: return focus to the composer after undo. The page owns the
  // editor key; if a direct ref isn't reachable from here, drop this call —
  // focus simply stays where it was.
}
```

> If `_noteEditorKey` is reachable (it is a State field on the page), prefer calling `_noteEditorKey.currentState?.focus()` from within the page rather than the free function — move `_PendingSendRow` to a method on the State, or pass an `onUndo` callback down. Keep it simple: a closure on the State that calls `_noteEditorKey.currentState?.focus()` after `restoreDraft`.

- [ ] **Step 2: Esc undoes a pending send first**

In the Esc branch of the page key handler (lines 668–680), add the undo check at the very top:

```dart
if (event.logicalKey == LogicalKeyboardKey.escape) {
  final threadBloc = context.read<ThreadBloc>();

  // Undo a SENDING note for this thread before any other Escape behavior.
  if (PendingSend.instance.isPending &&
      PendingSend.instance.pendingThreadId == threadBloc.state.thread.id) {
    final note = await PendingSend.instance.undo();
    threadBloc.restoreDraft(note);
    _noteEditorKey.currentState?.focus();
    return KeyEventResult.handled;
  }

  // ... existing editingNote / clearFocus logic, unchanged ...
}
```

If the enclosing handler is not already `async`, make it `async` (it returns `KeyEventResult`; an async key handler returns `Future<KeyEventResult>` only if the API allows — if it must stay sync, call `PendingSend.instance.undo()` without awaiting and use `.then`/ignore the return, fetching the note synchronously via `PendingSend.instance.pendingNote` BEFORE calling `undo()`):

```dart
  if (PendingSend.instance.isPending &&
      PendingSend.instance.pendingThreadId == threadBloc.state.thread.id) {
    final note = PendingSend.instance.pendingNote;
    unawaited(PendingSend.instance.undo());
    threadBloc.restoreDraft(note);
    _noteEditorKey.currentState?.focus();
    return KeyEventResult.handled;
  }
```

Add imports to `thread.dart` if missing: `import 'package:plot/state/pending_send.dart';` and `import 'dart:async';` (for `unawaited`).

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/thread.dart`
Expected: clean.

- [ ] **Step 4: Manual smoke via run-app (defer full assertion to Task 8)**

This page wiring is best verified by running the app (Task 8). For now ensure it compiles and the widget tree builds.

- [ ] **Step 5: Commit**

```bash
git add lib/page/thread.dart
git commit -m "feat(notes): render SENDING row + Esc-to-undo in thread view"
```

---

## Task 6: Flush pending send on app-close and sign-out

**Files:**
- Modify: `apps/plot/lib/widget/window.dart` (`_onExitRequested`, lines 327–337)
- Modify: `apps/plot/lib/base.dart` (`signOut`, lines 490–524)

**Interfaces:**
- Consumes: `PendingSend.instance.flush()` (Task 1).
- Produces: any in-flight note is committed (published + pushed) before the app closes / the session is cleared.

- [ ] **Step 1: Flush during shutdown**

In `apps/plot/lib/widget/window.dart`, in `_onExitRequested` (after `Window._saveWindowState();`, line 329, BEFORE `_hideWindowForShutdown()`), add:

```dart
    // Commit any in-flight "SENDING" note immediately so a quit during the
    // undo window still sends it. flush() awaits the local save and enqueues
    // the push; Store.stop()'s drain (below) waits for the push to complete.
    try {
      await PendingSend.instance.flush();
    } catch (e, t) {
      log.warning('Failed to flush pending send on shutdown', e, t);
    }
```

Add `import 'package:plot/state/pending_send.dart';` to `window.dart`.

- [ ] **Step 2: Flush on sign-out**

In `apps/plot/lib/base.dart`, at the very top of `signOut()` (before `base._userId = null;`, line 497), add:

```dart
    // Send any in-flight "SENDING" note under the still-authenticated session
    // before clearing identity.
    try {
      await PendingSend.instance.flush();
    } catch (e, t) {
      log.warning('Failed to flush pending send on sign-out', e, t);
    }
```

Add `import 'package:plot/state/pending_send.dart';` to `base.dart` if not already imported.

> `flush()` is a no-op when nothing is pending, so this is safe on every shutdown/sign-out. `log` is already in scope in both files (used nearby).

- [ ] **Step 3: Analyze + commit**

```bash
cd apps/plot
flutter analyze lib/widget/window.dart lib/base.dart
git add lib/widget/window.dart lib/base.dart
git commit -m "feat(notes): flush pending send on app-close and sign-out"
```

---

## Task 7: Full-suite lint/test + docs

**Files:**
- Modify: `apps/plot/docs/updates.md` (root `docs/updates.md`)
- Modify: `docs/features.md`

- [ ] **Step 1: Run the whole app test suite + analyze**

```bash
cd apps/plot
flutter analyze
flutter test
```
Expected: no new analyzer errors; the new tests pass and no existing test regresses. Investigate and fix any failure before proceeding.

- [ ] **Step 2: Add a user-facing changelog entry**

In `docs/updates.md`, under `## Next release` (create it at the very top if the most recent heading is a stamped `## <version> — <date>`), add a `### Sending notes` section (or fold into an existing send-related section if one exists):

```markdown
### Sending notes

- Just sent a note and want it back? For five seconds after you send, the note shows a **SENDING** button where the author and time normally appear — click it, or press Esc, to pull the message back into the editor. Works for replies and for the first note of a new thread. If you close the app or sign out during those five seconds, the note sends right away.
```

- [ ] **Step 3: Note the capability in `docs/features.md`**

Add a brief bullet to the relevant notes/messaging section describing the 5-second undo-send window.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md ../../docs/features.md
git commit -m "docs(notes): undo-send changelog + feature note"
```

---

## Task 8: Verify in the running app

**Files:** none (manual verification)

- [ ] **Step 1: Launch the app**

Use the `run-app` skill to launch Plot.app in the isolated agent profile and connect dart-mcp.

- [ ] **Step 2: Walk the spec's behaviors**

Confirm each, observing via the widget tree / screenshots:

1. **Existing-thread send:** open a thread, type, send → the note shows `SENDING ✕` in the author slot; after ~5s the footer flips to author + time and the note is in the list (synced).
2. **Undo via button:** send, click `SENDING ✕` within 5s → the note leaves the list and its text returns to the composer.
3. **Undo via Esc:** send, press Esc within 5s → same as (2).
4. **New-thread send:** compose a new thread, send → you land in the thread view, the note shows `SENDING`; after ~5s the thread leaves drafts (visible in feeds) and the note syncs.
5. **New-thread undo + abandon:** send a new thread, undo, navigate away without re-sending → the thread reappears in the NewThreadPage drafts list; its content is intact.
6. **One-at-a-time:** send note A, then quickly send note B while A is still `SENDING` → A commits immediately (footer flips), B starts its own window.
7. **Editor-has-text on undo:** send, type new text, then undo → the restored content replaces the typed text.
8. **Close while SENDING:** send, quit the app within 5s, relaunch → the note is sent (present in the thread, not lost).

- [ ] **Step 3: Run `/finalize`**

Run the `finalize` skill (lint, backwards-compat, error-capture, docs, public submodule). Address anything it flags.

---

## Self-Review (completed by plan author)

- **Spec coverage:** SENDING footer in author slot → Task 4; 5s window → Task 1 (`window`); click-to-undo → Task 4/5; Esc-to-undo → Task 5; existing-thread send → Task 2; new-thread send staying in draft + drafts-on-abandon → Task 3; one-at-a-time → Task 1 (`start` commits prior); close/sign-out sends immediately → Task 6; replace-editor-text on undo → Task 2 (`restoreDraft` emits a fresh draft, the editor's `didUpdateWidget` resets to it). All covered.
- **No schema change:** confirmed — nothing new is persisted; the new thread reuses its existing `draft` row, the reply note is held in memory until commit.
- **Type consistency:** `PendingSend.start(note:, newThread:)`, `commit()`, `undo()→Note?`, `flush()`, `isPending`, `pendingNote`, `pendingThreadId`, `window` are used identically in Tasks 2/3/5/6. `NoteWidget(sending:, onUndoSend:)` defined in Task 4 and consumed in Task 5. `ThreadBloc.sendWithUndo`/`restoreDraft` defined in Task 2, consumed in Tasks 4-route/5. `PriorityBloc.resetDraftAfterSend` defined and used in Task 3.
- **Known best-effort edges (documented, acceptable per spec):** BCC-drop and mentions→contacts run at submit, so undoing a note that added a BCC/mention leaves that thread-contact change in place; a hard crash (not a graceful close) during the window loses an existing-thread note's text (a new-thread note survives as its draft). Both are within the spec ("graceful close/sign-out sends immediately").
