# Thread note initial expand/collapse + scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On opening a thread, render notes with context-aware initial expand state and scroll position: a lone note opens expanded and scrolled to its top; with multiple notes, unread notes open expanded and the list scrolls to the top of the oldest unread note; when nothing is detectably unread, behavior is unchanged.

**Architecture:** A small pure module (`lib/util/note_initial_view.dart`) decides, from the thread's pre-open read snapshot, which notes start expanded and which note (if any) the list should scroll to. `_TruncatedNoteContent` gains an `initiallyExpanded` seed. `ThreadPage` snapshots `readAt`/`unread` before its 750 ms mark-as-read timer fires, feeds the pure helpers into each `NoteWidget`, tags the scroll-target note with a `GlobalKey`, and performs a one-shot post-layout scroll using `RenderAbstractViewport.getOffsetToReveal`.

**Tech Stack:** Flutter (forui), `flutter_bloc`, Drift store models, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-05-30-thread-note-initial-expand-scroll-design.md`

---

### Task 1: Pure decision module (`note_initial_view.dart`)

Pure, widget-free functions so the unread/expand/scroll-target logic is unit-testable without a render tree. All decisions key off a snapshot of the thread's `unread` flag and `readAt` taken when the page opened.

**Files:**
- Create: `apps/plot/lib/util/note_initial_view.dart`
- Test: `apps/plot/test/util/note_initial_view_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/util/note_initial_view_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/note_initial_view.dart';

Note _note(DateTime sourceCreatedAt) => Note(
  id: Uuid.generate(),
  threadId: Uuid.generate(),
  authorId: ActorId(Uuid.generate()),
  draft: false,
  createdAt: sourceCreatedAt,
  sourceCreatedAt: sourceCreatedAt,
  updatedAt: sourceCreatedAt,
);

void main() {
  final t1 = DateTime(2026, 1, 1, 9);
  final t2 = DateTime(2026, 1, 1, 10);
  final t3 = DateTime(2026, 1, 1, 11);

  group('noteIsUnread', () {
    test('read thread (unread flag false) has no unread notes', () {
      expect(
        noteIsUnread(_note(t3), threadUnread: false, readAt: t1),
        isFalse,
      );
    });

    test('null readAt with unread thread treats note as unread', () {
      expect(
        noteIsUnread(_note(t1), threadUnread: true, readAt: null),
        isTrue,
      );
    });

    test('note after readAt is unread; at-or-before is read', () {
      expect(noteIsUnread(_note(t3), threadUnread: true, readAt: t2), isTrue);
      expect(noteIsUnread(_note(t2), threadUnread: true, readAt: t2), isFalse);
      expect(noteIsUnread(_note(t1), threadUnread: true, readAt: t2), isFalse);
    });
  });

  group('noteInitiallyExpanded', () {
    test('single note always expanded, even when read', () {
      expect(
        noteInitiallyExpanded(
          _note(t1),
          noteCount: 1,
          threadUnread: false,
          readAt: t3,
        ),
        isTrue,
      );
    });

    test('multiple notes: unread expands, read collapses', () {
      expect(
        noteInitiallyExpanded(
          _note(t3),
          noteCount: 3,
          threadUnread: true,
          readAt: t2,
        ),
        isTrue,
      );
      expect(
        noteInitiallyExpanded(
          _note(t1),
          noteCount: 3,
          threadUnread: true,
          readAt: t2,
        ),
        isFalse,
      );
    });
  });

  group('initialScrollTargetIndex', () {
    test('empty list -> null', () {
      expect(
        initialScrollTargetIndex([], threadUnread: true, readAt: null),
        isNull,
      );
    });

    test('single note -> index 0', () {
      expect(
        initialScrollTargetIndex(
          [_note(t1)],
          threadUnread: false,
          readAt: t3,
        ),
        0,
      );
    });

    test('multiple with unread -> oldest unread (min sourceCreatedAt)', () {
      // notes in arbitrary order; t2 and t3 are unread (readAt = t1).
      final notes = [_note(t3), _note(t1), _note(t2)];
      // Oldest unread is t2, at index 2.
      expect(
        initialScrollTargetIndex(notes, threadUnread: true, readAt: t1),
        2,
      );
    });

    test('multiple, none unread -> null', () {
      final notes = [_note(t1), _note(t2), _note(t3)];
      expect(
        initialScrollTargetIndex(notes, threadUnread: false, readAt: t1),
        isNull,
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/util/note_initial_view_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:plot/util/note_initial_view.dart'` (the module is not created yet).

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/util/note_initial_view.dart`:

```dart
import 'package:plot/store/store.dart';

/// True when [note] should be treated as unread, given a snapshot of the
/// thread's read state captured when the page opened.
///
/// [threadUnread] is the thread's `unread` flag and [readAt] its `readAt`,
/// both snapshotted before ThreadPage's mark-as-read timer resets them. A
/// fully-read thread (`threadUnread == false`) has no unread notes. With an
/// unread thread, a note is unread when it was created after the read
/// boundary (or there is no boundary yet).
bool noteIsUnread(
  Note note, {
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (!threadUnread) return false;
  return readAt == null || note.sourceCreatedAt.isAfter(readAt);
}

/// Whether [note] should start expanded (untruncated) on first paint.
///
/// A lone note is always expanded. With multiple notes, only unread notes
/// start expanded; read notes keep the default height-truncation.
bool noteInitiallyExpanded(
  Note note, {
  required int noteCount,
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (noteCount <= 1) return true;
  return noteIsUnread(note, threadUnread: threadUnread, readAt: readAt);
}

/// Index into [notes] of the note whose top the list should scroll to on
/// open, or null when the list should keep its default (newest-at-bottom)
/// position.
///
/// - single note          -> 0
/// - multiple, has unread  -> the oldest unread note (min `sourceCreatedAt`)
/// - multiple, none unread -> null
///
/// Order-independent: the target is found by timestamp, so it does not
/// matter whether [notes] is newest- or oldest-first.
int? initialScrollTargetIndex(
  List<Note> notes, {
  required bool threadUnread,
  required DateTime? readAt,
}) {
  if (notes.isEmpty) return null;
  if (notes.length == 1) return 0;
  int? targetIndex;
  DateTime? targetTime;
  for (var i = 0; i < notes.length; i++) {
    if (!noteIsUnread(notes[i], threadUnread: threadUnread, readAt: readAt)) {
      continue;
    }
    final t = notes[i].sourceCreatedAt;
    if (targetTime == null || t.isBefore(targetTime)) {
      targetTime = t;
      targetIndex = i;
    }
  }
  return targetIndex;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/util/note_initial_view_test.dart`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/util/note_initial_view.dart apps/plot/test/util/note_initial_view_test.dart
git commit -m "feat: pure helpers for thread note initial expand/scroll"
```

---

### Task 2: Seed `_TruncatedNoteContent` with `initiallyExpanded`

Thread an `initiallyExpanded` flag from `NoteWidget` into `_TruncatedNoteContent`, and seed the existing `_expanded` state from it in `initState`. Seeding (not recomputing on build) means a later rebuild with a fresh `readAt` will not re-collapse an already-expanded note, matching the current "once expanded, stays expanded" behavior.

**Files:**
- Modify: `apps/plot/lib/widget/note.dart` (`NoteWidget` constructor + the `_TruncatedNoteContent` call site ~190; `_TruncatedNoteContent` ~397; `_TruncatedNoteContentState` ~429)

- [ ] **Step 1: Add `initiallyExpanded` to `NoteWidget`**

In `apps/plot/lib/widget/note.dart`, change the `NoteWidget` constructor and fields (lines 86–106). Add the parameter and field:

```dart
class NoteWidget extends StatefulWidget {
  const NoteWidget({
    required this.note,
    this.selected = false,
    this.dimmed = false,
    this.focusNode,
    this.onHover,
    this.reorderableIndex,
    this.showAuthor = true,
    this.searchHighlight,
    this.initiallyExpanded = false,
    super.key,
  });

  final Note note;
  final bool selected;
  final bool dimmed;
  final FocusNode? focusNode;
  final void Function(bool hovered)? onHover;
  final int? reorderableIndex;
  final bool showAuthor;
  final String? searchHighlight;

  /// Whether the note's content should start fully expanded (untruncated)
  /// instead of height-truncated with the "View all" fade. Set by ThreadPage
  /// for a lone note or for unread notes. See `util/note_initial_view.dart`.
  final bool initiallyExpanded;

  @override
  State<NoteWidget> createState() => _NoteWidgetState();
}
```

- [ ] **Step 2: Forward the flag at the `_TruncatedNoteContent` call site**

In `apps/plot/lib/widget/note.dart` (~line 187–195), pass the flag through:

```dart
          if (noteContent.isNotEmpty)
            Padding(
              padding: .symmetric(horizontal: 6),
              child: _TruncatedNoteContent(
                note: widget.note,
                searchHighlight: widget.searchHighlight,
                noteHovered: _hovered,
                initiallyExpanded: widget.initiallyExpanded,
              ),
            ),
```

- [ ] **Step 3: Add the field to `_TruncatedNoteContent` and seed state**

In `apps/plot/lib/widget/note.dart`, update the `_TruncatedNoteContent` constructor and fields (lines 397–410):

```dart
class _TruncatedNoteContent extends StatefulWidget {
  const _TruncatedNoteContent({
    required this.note,
    required this.noteHovered,
    this.searchHighlight,
    this.initiallyExpanded = false,
  });

  final Note note;
  final String? searchHighlight;

  /// Whether the parent note widget is currently hovered. The "View all"
  /// signifier only renders while this is true; otherwise it stays hidden
  /// so the inline view is uncluttered.
  final bool noteHovered;

  /// Whether the note starts expanded (untruncated) on first build.
  final bool initiallyExpanded;
```

Then in `_TruncatedNoteContentState` (line 429–432), change the `_expanded` declaration to be seeded in `initState`:

```dart
class _TruncatedNoteContentState extends State<_TruncatedNoteContent> {
  bool _overflow = false;
  bool _fadeHovered = false;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }
```

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/note.dart`
Expected: "No issues found!" (no new analyzer errors/warnings from these edits).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/note.dart
git commit -m "feat: NoteWidget initiallyExpanded seeds note expansion"
```

---

### Task 3: Snapshot read state and wire per-note expansion in `ThreadPage`

Capture `readAt`/`unread` before the 750 ms mark-as-read timer fires, and pass each note's computed `initiallyExpanded` into its `NoteWidget`.

**Files:**
- Modify: `apps/plot/lib/page/thread.dart` (imports ~1–20; state fields ~65–85; `didChangeDependencies` ~88–97; `_buildItemAtIndex` ~586–608)

- [ ] **Step 1: Add the import**

In `apps/plot/lib/page/thread.dart`, add to the local import group (after line 14 `import 'package:plot/state/thread.dart';`):

```dart
import 'package:plot/util/note_initial_view.dart';
```

- [ ] **Step 2: Add snapshot fields**

In `apps/plot/lib/page/thread.dart`, after the `_markReadTimer` field (line 82), add:

```dart
  // Snapshot of the thread's read state captured when the page opened,
  // BEFORE the 750ms mark-as-read timer resets readAt. Drives which notes
  // start expanded and which note the list scrolls to. See
  // util/note_initial_view.dart.
  DateTime? _initialReadAt;
  bool _initialThreadUnread = false;
  bool _readSnapshotTaken = false;
```

- [ ] **Step 3: Take the snapshot in `didChangeDependencies`**

In `apps/plot/lib/page/thread.dart`, replace lines 91–96:

```dart
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    _priorityBloc = context.read<PriorityBloc>();
    _threadId = context.read<ThreadBloc>().state.thread.id;
    // Schedule marking thread as read after 750ms
    _scheduleMarkAsRead();
```

with:

```dart
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    _priorityBloc = context.read<PriorityBloc>();
    final thread = context.read<ThreadBloc>().state.thread;
    _threadId = thread.id;
    // Snapshot read state once, before _scheduleMarkAsRead's timer resets it.
    if (!_readSnapshotTaken) {
      _readSnapshotTaken = true;
      _initialReadAt = thread.readAt;
      _initialThreadUnread = thread.unread;
    }
    // Schedule marking thread as read after 750ms
    _scheduleMarkAsRead();
```

- [ ] **Step 4: Pass `initiallyExpanded` per note**

In `apps/plot/lib/page/thread.dart`, in `_buildItemAtIndex` (~586–608), update the `NoteWidget` construction to add `initiallyExpanded`:

```dart
    final note = _getNoteAtIndex(state, index);
    if (note != null) {
      return NoteWidget(
        note: note,
        selected: false, // No selection on ThreadPage
        dimmed: state.editingNote?.id == note.id,
        focusNode: focusNode,
        key: ValueKey(note.id),
        reorderableIndex: reorderableIndex,
        showAuthor: state.hasOtherAuthors,
        searchHighlight: state.search.isNotEmpty ? state.search : null,
        initiallyExpanded: noteInitiallyExpanded(
          note,
          noteCount: state.notes.length,
          threadUnread: _initialThreadUnread,
          readAt: _initialReadAt,
        ),
      );
    }
    return const SizedBox.shrink();
```

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/thread.dart`
Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/page/thread.dart
git commit -m "feat: ThreadPage seeds per-note expansion from read snapshot"
```

---

### Task 4: One-shot initial scroll to the target note's top

Tag the target note with a `GlobalKey`, then after the first layout scroll the list so the target's top sits at the viewport top. Uses `RenderAbstractViewport.getOffsetToReveal(target, 1.0)`, which — in the `reverse: true` (AxisDirection.up) list — aligns the note's top edge to the viewport's visual top. The target may be off the initial (bottom) view, so the routine nudges the list toward older notes a page at a time until the target is laid out, then reveals it precisely. Bounded retries prevent looping.

`MouseRegion` wrappers in `InfiniteList` key off the provided `itemKey` (note id), not the child's key, so giving the target `NoteWidget` a `GlobalKey` does not collide.

**Files:**
- Modify: `apps/plot/lib/page/thread.dart` (imports ~1–20; state fields ~65–85; `_buildContent` ~234; `_buildItemAtIndex` ~586–608; new methods)

- [ ] **Step 1: Add the rendering import**

In `apps/plot/lib/page/thread.dart`, add to the framework import group (after line 3 `import 'package:flutter/services.dart';`):

```dart
import 'package:flutter/rendering.dart';
```

- [ ] **Step 2: Add scroll-target fields**

In `apps/plot/lib/page/thread.dart`, after the snapshot fields added in Task 3, add:

```dart
  // Initial scroll: the note whose top the list scrolls to on open, tagged
  // with this GlobalKey so its render object can be located. Computed once
  // when notes first arrive; the scroll runs once post-layout.
  final GlobalKey _scrollTargetKey = GlobalKey();
  int? _scrollTargetIndex;
  bool _initialScrollScheduled = false;
```

- [ ] **Step 3: Schedule the one-shot scroll from `_buildContent`**

In `apps/plot/lib/page/thread.dart`, at the very start of `_buildContent` (immediately after line 234 `Widget _buildContent(BuildContext context, ThreadState state) {`), add:

```dart
    // One-time: once notes exist, pick the scroll target and (if any) scroll
    // to its top after layout. Computing the index here (before the item
    // builders run) ensures the target note gets _scrollTargetKey on its
    // first build.
    if (!_initialScrollScheduled && state.notes.isNotEmpty) {
      _initialScrollScheduled = true;
      _scrollTargetIndex = initialScrollTargetIndex(
        state.notes,
        threadUnread: _initialThreadUnread,
        readAt: _initialReadAt,
      );
      if (_scrollTargetIndex != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _revealScrollTarget(attempt: 0);
        });
      }
    }
```

- [ ] **Step 4: Tag the target note with the GlobalKey**

In `apps/plot/lib/page/thread.dart`, in `_buildItemAtIndex` (edited in Task 3), change the `key:` line so the target note uses `_scrollTargetKey`:

```dart
        key: _scrollTargetIndex == index
            ? _scrollTargetKey
            : ValueKey(note.id),
```

- [ ] **Step 5: Add the `_revealScrollTarget` method**

In `apps/plot/lib/page/thread.dart`, add this method to `_ThreadPageContentState` (e.g. directly after `_scheduleMarkAsRead`, ~line 178):

```dart
  /// Scrolls the (reverse) note list so the scroll-target note's top aligns
  /// to the viewport top. The target may not be laid out yet (it sits above
  /// the initial bottom view), so we nudge toward older notes a page at a
  /// time until it builds, then reveal it precisely. Bounded retries.
  void _revealScrollTarget({required int attempt}) {
    final controller = ScrollControllerContext.of(context);
    if (controller == null || !controller.hasClients) {
      if (attempt >= 10) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealScrollTarget(attempt: attempt + 1);
      });
      return;
    }

    final renderObject = _scrollTargetKey.currentContext?.findRenderObject();
    if (renderObject != null && renderObject.attached) {
      final viewport = RenderAbstractViewport.of(renderObject);
      // alignment 1.0: in the reverse (AxisDirection.up) list the note's top
      // edge (its trailing edge) aligns to the viewport's trailing edge —
      // i.e. the note's top sits at the visual top of the viewport.
      final reveal = viewport
          .getOffsetToReveal(renderObject, 1.0)
          .offset
          .clamp(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          )
          .toDouble();
      controller.jumpTo(reveal);
      return;
    }

    // Target not built yet: scroll toward older notes (up, increasing offset
    // in a reverse list) by a page and retry.
    if (attempt >= 10) return;
    final next = (controller.offset + controller.position.viewportDimension)
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    if (next <= controller.offset) return; // already at the top; cannot reveal
    controller.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealScrollTarget(attempt: attempt + 1);
    });
  }
```

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/thread.dart`
Expected: "No issues found!"

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/page/thread.dart
git commit -m "feat: ThreadPage scrolls to top of first unread note on open"
```

---

### Task 5: Repo-wide verify, manual check, and changelog

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: "No issues found!" (or only pre-existing, unrelated issues — none introduced by Tasks 1–4).

- [ ] **Step 2: Run the unit tests**

Run: `cd apps/plot && flutter test test/util/note_initial_view_test.dart`
Expected: PASS.

- [ ] **Step 3: Manual verification (real app)**

The scroll behavior depends on live render geometry and the lazy reverse list, which unit tests do not exercise. Verify manually via the `run-app` skill. Confirm each case:
- **Single-note thread (long note):** opens with the note expanded (no "View all" fade) and scrolled to its top.
- **Multi-note thread with unread notes:** unread notes are expanded, older read notes stay truncated, and the list opens at the top of the oldest unread note.
- **Multi-note thread fully read:** unchanged — all long notes truncated, list rests at the newest (bottom) note.

Note any deviation; do not claim success without observing these.

- [ ] **Step 4: Add a changelog entry**

In `docs/updates.md`, add a bullet to the top (current) section, in plain user language:

```markdown
- Opening a thread now starts you at the first unread note (expanded), instead of always jumping to the bottom. Single-note threads open at the top of the note.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs: changelog for thread note initial expand/scroll"
```

---

## Self-Review

**Spec coverage:**
- Unread definition (`readAt == null || sourceCreatedAt.isAfter(readAt)`, gated by `unread` flag) → Task 1 `noteIsUnread` + tests.
- Snapshot before mark-as-read → Task 3 Step 3.
- Single note expanded → Task 1 `noteInitiallyExpanded` (noteCount<=1) + Task 2 seeding.
- Multiple: unread expanded, read truncated → Task 1 + Task 3 Step 4.
- Single note scroll to top → Task 1 returns index 0 + Task 4 reveal.
- Multiple+unread scroll to oldest unread top → Task 1 `initialScrollTargetIndex` + Task 4 reveal.
- Multiple+no-unread: no scroll, unchanged collapse → Task 1 returns null (no key, no scroll); Task 3 collapses read notes.
- One-shot guard → Task 4 `_initialScrollScheduled`.
- Reverse-list alignment → Task 4 `getOffsetToReveal(.., 1.0)` with comment.
- No schema change / no divider UI → none added.

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. The one deferred concern in the spec (exact offset math) is now concrete in Task 4 Step 5.

**Type consistency:** `noteIsUnread`, `noteInitiallyExpanded`, `initialScrollTargetIndex` signatures match between Task 1 definition and Task 3/Task 4 call sites (`threadUnread:`, `readAt:`, `noteCount:`). `_scrollTargetKey`, `_scrollTargetIndex`, `_initialScrollScheduled`, `_initialReadAt`, `_initialThreadUnread`, `_readSnapshotTaken` are declared once (Tasks 3–4) and used consistently. `_revealScrollTarget({required int attempt})` is declared once and called with `attempt:` everywhere.
