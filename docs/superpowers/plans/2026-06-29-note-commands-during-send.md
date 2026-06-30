# Note Commands During the Send (Undo) Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a note is in its 5-second "undo send" window, show the bottom-left note commands (to-do, react, reply, more) — keeping the `sending ✕` undo affordance — and prevent an orphaned reaction if such a note is undone.

**Architecture:** The sent note is already a real `draft:false` row; only its remote push is held by `PendingSend` + `Store.pushHeldNoteIds`. So (1) we stop discarding the footer during `sending` and render `NoteCommands` exactly as on a normal note, with the `sending ✕` button occupying the right slot where author/timestamp normally is; and (2) we add a `note_reactions` clause to `Store._buildDraftFilter` so a reaction added during the window and then undone (note → `draft+archived`) can't push against a never-sent note. No change to `PendingSend`, the command classes, or `NoteCommands` itself.

**Tech Stack:** Flutter/Dart, forui widgets, Drift (SQLite), `flutter_test`.

## Global Constraints

- UI: forui widgets only — import `flutter/widgets.dart` and `forui/forui.dart`, never `flutter/material.dart`.
- Strict typing (`strict-casts`, `strict-inference`, `strict-raw-types`). `flutter analyze` must be clean before commit.
- Widgets stay stateless except for local UI state; do not reference Bloc state in widgets beyond what `NoteCommands`/`NoteWidget` already do.
- No schema/migration change. Do NOT touch migration files or bump `Store.schemaVersion`.
- `note_reactions` is a real synced table keyed on the parent note's id (table `note_reactions`, columns from `SyncableTable` + `UuidTable`: `id` blob PK, `pending` int nullable, `updatedAt`, plus `reactions`/`reactionsUpdated`). It does NOT have a `createdAt`/`draft`/`thread_id` column.
- Sentence case for any user-facing text (none added here).
- Decision (locked): acting on a sending note does NOT end the undo window — no commit-on-action.

---

## Task 1: `note_reactions` draft filter (orphan-reaction fix)

Add the missing draft-filter clause so a reaction whose parent note is a draft is excluded from the push claim, mirroring the existing `note_tags` clause. This is what makes the undo path safe once reactions can be added during the window.

**Files:**
- Modify: `apps/plot/lib/store/store.dart` — `_buildDraftFilter` (currently ~1490–1521) and add a `@visibleForTesting` accessor next to it.
- Test: `apps/plot/test/store/draft_filter_test.dart` (create)

**Interfaces:**
- Produces: `Store.buildDraftFilter(TableInfo<Table, DataClass> table) → String` (a `@visibleForTesting` static delegating to the private `_buildDraftFilter`). Returns the SQL fragment (`' AND …'` or `''`) appended to a push-claim `WHERE`.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Add the `@visibleForTesting` accessor (test infrastructure, no behavior change)**

In `apps/plot/lib/store/store.dart`, immediately after the closing brace of the private `_buildDraftFilter` method, add:

```dart
  /// Test-only access to [_buildDraftFilter].
  @visibleForTesting
  static String buildDraftFilter(TableInfo<Table, DataClass> table) =>
      _buildDraftFilter(table);
```

(`@visibleForTesting` and `TableInfo`/`Table`/`DataClass` are already imported/used in this file — see the existing `_buildDraftFilter` signature and the other `@visibleForTesting` statics like `isTransientPushError`.)

- [ ] **Step 2: Write the failing test**

Create `apps/plot/test/store/draft_filter_test.dart`:

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

final _noteId = NoteId.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd');
final _threadId = ThreadId.fromString('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
final _self = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

Future<void> _insertNote(Store store, {required bool draft}) async {
  await store.into(store.notes).insert(
        NotesCompanion(
          id: Value(_noteId),
          threadId: Value(_threadId),
          authorId: Value(_self),
          draft: Value(draft),
          content: const Value('hi'),
          createdAt: Value(DateTime(2026)),
          sourceCreatedAt: Value(DateTime(2026)),
          updatedAt: Value(DateTime(2026)),
          pending: const Value(2),
        ),
      );
}

Future<void> _insertReaction(Store store) async {
  await store.into(store.noteReactions).insert(
        NoteReactionsCompanion(
          id: Value(_noteId),
          pending: const Value(2),
        ),
      );
}

/// Count of note_reactions rows the push claim would send, applying the
/// draft filter exactly as `Store.push` does.
Future<int> _claimable(Store store) async {
  final filter = Store.buildDraftFilter(store.noteReactions);
  final row = await store
      .customSelect(
        'SELECT count(*) AS c FROM note_reactions '
        'WHERE pending IS NOT NULL $filter',
      )
      .getSingle();
  return row.read<int>('c');
}

void main() {
  late Store store;

  setUp(() => store = Store.forTesting(NativeDatabase.memory()));
  tearDown(() async => store.close());

  test('a draft note\'s reaction is excluded from the push claim', () async {
    await _insertNote(store, draft: true);
    await _insertReaction(store);
    expect(await _claimable(store), 0,
        reason: 'reaction on a draft note must not push (would 404)');
  });

  test('a published note\'s reaction stays claimable', () async {
    await _insertNote(store, draft: false);
    await _insertReaction(store);
    expect(await _claimable(store), 1,
        reason: 'reaction on a real note must still sync');
  });
}
```

- [ ] **Step 3: Run the test to verify the draft case fails**

Run: `cd apps/plot && flutter test test/store/draft_filter_test.dart`
Expected: the first test FAILS (`Expected: 0 / Actual: 1`) because `_buildDraftFilter` returns `''` for `note_reactions` today, so the reaction is not excluded. The second test passes. (If both compile and the first fails on the count assertion, that's the correct red.)

- [ ] **Step 4: Add the `note_reactions` clause**

In `apps/plot/lib/store/store.dart`, in `_buildDraftFilter`, extend the `note_tags` special-case to also cover `note_reactions`. Change:

```dart
    if (name == 'note_tags') {
      return ' AND id NOT IN (SELECT id FROM notes WHERE draft = 1)';
    }
```

to:

```dart
    // note_tags / note_reactions share the parent note's id, so exclude any
    // whose note is a draft — covers a reaction added during a note's undo-send
    // window that is then undone (the note flips to draft + archived).
    if (name == 'note_tags' || name == 'note_reactions') {
      return ' AND id NOT IN (SELECT id FROM notes WHERE draft = 1)';
    }
```

(Leave the `thread_tags` clause and everything else unchanged.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/draft_filter_test.dart`
Expected: PASS (2 tests, 0 failures).

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/note-commands-during-send
git add apps/plot/lib/store/store.dart apps/plot/test/store/draft_filter_test.dart
git commit -m "fix(store): exclude draft-note reactions from the push claim

Mirror the note_tags draft filter for note_reactions so a reaction added
during a note's undo-send window and then undone can't push against a
never-sent note (404).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Render `NoteCommands` during the send window

Stop replacing the footer during `sending`. Render the same `Stack` always: the `sending ✕` button in the right slot, `NoteCommands` in the left slot (both states).

**Files:**
- Modify: `apps/plot/lib/widget/note.dart` — the `SizedBox(height: 30, …)` footer block (currently ~250–426, inside `_NoteWidgetState.build`).
- Verify: `cd apps/plot && flutter analyze`; then run-app manual check.

**Interfaces:**
- Consumes: `widget.sending` (bool), `widget.onUndoSend` (`VoidCallback?`), `widget.note`, `widget.selected`, `widget.showAuthor`, local `_hovered` (bool), `hasFocus` — all already in scope in this build method. `NoteCommands({required Note note, bool showCommands, Color? tileBg})` (unchanged).
- Produces: nothing for later tasks.

- [ ] **Step 1: Replace the footer block**

In `apps/plot/lib/widget/note.dart`, replace the entire `SizedBox(height: 30, child: widget.sending ? … : Stack(…))` block (the one starting `SizedBox(` at ~250 and ending with the matching `),` before the `],` at ~426–427) with the following. This keeps the author/timestamp subtree and the `sending ✕`/`NoteCommands` subtrees byte-for-byte; it only changes how they're arranged (three `Stack` children gated by `if`):

```dart
          SizedBox(
            height: 30,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Right slot, normal state: author/timestamp.
                if (!widget.sending)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Builder(
                      builder: (context) {
                        final mutedXs = context.theme.typography.xs
                            .copyWith(color: context.colour.muted);
                        final timeAgo = FTooltip(
                          tipBuilder: (context, controller) => Text(
                            widget.note.sourceCreatedAt.toLocal().format(
                              'MMM d, yyyy, h:mm a',
                            ),
                          ),
                          child: Text(
                            widget.note.sourceCreatedAt.toTimeAgo(),
                            style: mutedXs,
                          ),
                        );
                        Widget withPending(Widget child) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PendingSyncIndicator(note: widget.note),
                            child,
                          ],
                        );
                        if (!widget.showAuthor) return withPending(timeAgo);
                        return FutureBuilder<Actor?>(
                          future: widget.note.getAuthor(),
                          builder: (context, snapshot) {
                            final actor = snapshot.data;
                            final authorName = actor == null
                                ? null
                                : (widget.note.authorId.isCurrentUser
                                      ? 'You'
                                      : actor.nameOrEmail);
                            if (authorName == null || authorName.isEmpty) {
                              return withPending(timeAgo);
                            }
                            Widget authorText = Text(
                              authorName,
                              style: mutedXs,
                            );
                            if (actor?.email != null &&
                                actor!.email != authorName) {
                              authorText = FTooltip(
                                tipBuilder: (context, controller) =>
                                    Text(actor.email!),
                                child: authorText,
                              );
                            }
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _PendingSyncIndicator(note: widget.note),
                                if (actor != null) ...[
                                  Avatar(actor: actor, tooltip: false),
                                  const SizedBox(width: 4),
                                ],
                                authorText,
                                const SizedBox(width: 4),
                                Text('•', style: mutedXs),
                                const SizedBox(width: 4),
                                timeAgo,
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                // Right slot, send window: `sending ✕` cancel button. Ghost
                // buttons inset their content by the button's padding, so shift
                // right by that padding so the label lines up with where the
                // timestamps sit (flush at right: 0). Mirrors NoteCommands'
                // left-edge compensation.
                if (widget.sending)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Transform.translate(
                        offset: Offset(
                          context
                              .theme
                              .buttonStyles
                              .ghost
                              .md
                              .iconContentStyle
                              .padding
                              .resolve(TextDirection.ltr)
                              .right,
                          0,
                        ),
                        child: FTooltip(
                          tipBuilder: (context, controller) => Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Cancel'),
                              Text(
                                formatShortcut(
                                  const SingleActivator(
                                    LogicalKeyboardKey.escape,
                                  ),
                                ),
                                style: context.theme.typography.xs.copyWith(
                                  color: context.theme.colors.mutedForeground,
                                ),
                              ),
                            ],
                          ),
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
                              mainAxisAlignment: .center,
                              spacing: 4,
                              children: [
                                const Text('sending'),
                                Icon(
                                  FontAwesomeIcons.xmark,
                                  size: context.theme.iconSizes.xs,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Left slot: note commands, in BOTH states — so a note can be
                // marked to-do / reacted to while its send is still pending.
                // NoteCommands overlays the right slot with a solid background
                // and gradient fade so right-side content truncates cleanly.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(
                      6 -
                          context
                              .theme
                              .buttonStyles
                              .ghost
                              .md
                              .iconContentStyle
                              .padding
                              .resolve(TextDirection.ltr)
                              .left,
                      0,
                    ),
                    child: NoteCommands(
                      note: widget.note,
                      showCommands: _hovered,
                      tileBg: widget.selected
                          ? context.theme.colors.primaryForeground
                          : hasFocus
                          ? Color.alphaBlend(
                              context.theme.plotColors.highlight,
                              context.theme.colors.background,
                            )
                          : context.theme.colors.background,
                    ),
                  ),
                ),
              ],
            ),
          ),
```

- [ ] **Step 2: Verify analyzer is clean**

Run: `cd apps/plot && flutter analyze lib/widget/note.dart`
Expected: "No issues found!" (or no NEW issues vs. baseline for this file). Fix any analyzer error introduced by the edit (e.g. a mismatched paren) before continuing.

- [ ] **Step 3: Manual verification via run-app**

Invoke the `run-app` skill to launch the macOS app, then exercise (hot reload is fine):
1. Send a note (reply or new-thread first note that is shared, so the 5s window arms). Within the window, hover the note → the bottom-left commands (to-do / add reaction / reply / more) appear; the `sending ✕` button stays on the right.
2. Click "to do" during the window → the to-do chip appears and stays; `sending ✕` remains; wait out the window → note + to-do remain (sent).
3. Send another note; within the window add a reaction, then click `sending ✕` (or press Esc) → the note disappears (undone). Confirm no sync error/orphan: in the app's console there is no push 404 for `note-reactions`, and the reaction does not reappear.

Record what you observed (the run-app skill's screenshots/console). If step 1 shows the commands hidden, the `Stack` ordering or `if (!widget.sending)` gating is wrong — re-check Step 1.

- [ ] **Step 4: Add a user-facing update fragment**

Run: `cd /Users/kris.braun/code/plot/.claude/worktrees/note-commands-during-send && pnpm updates:new "Act on a note while it's still sending"`

Then edit the generated `docs/updates.d/<slug>-<id>.md` so it contains a bullet under an appropriate existing section (e.g. an existing notes/threads section if present; otherwise a `### Notes` section above `### Fixes`):

```markdown
### Notes

- You can now mark a note to-do, react, or reply while it's still in the
  send/undo window — no need to wait for it to finish sending.
```

(Keep wording plain; sentence case. If `pnpm updates:new` is unavailable in the worktree, hand-create the file following a sibling in `docs/updates.d/`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/note-commands-during-send
git add apps/plot/lib/widget/note.dart docs/updates.d/
git commit -m "feat(note): show note commands during the send/undo window

Render NoteCommands (to-do, react, reply, more) while a note is in its
5s undo-send window, with the sending/cancel button in the right slot.
Acting takes effect immediately and rides along with the held push (or is
undone with the note). No change to PendingSend.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Finalization

- [ ] **Run `flutter analyze` for the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: no new issues attributable to this change (the repo may have pre-existing analyzer output; compare against baseline).

- [ ] **Invoke `/finalize`** to run the project's finalization checklist (lint, backwards-compat, error capture, docs, submodule). There is no `public/` change and no new `catch` block here, so those sections are no-ops; the docs fragment from Task 2 Step 4 satisfies the docs item.

- [ ] **Offer next steps** (open a PR via the finishing-a-development-branch skill, or leave the branch for review) per the user's preference.

---

## Self-Review

**Spec coverage:**
- Footer renders `NoteCommands` during the window with `sending ✕` retained → Task 2 Step 1. ✓
- Commands work on the real row, held push carries them → no code needed (existing `_buildHoldFilter` covers `note_tags`/`note_reactions`); verified in Task 2 Step 3. ✓
- `note_reactions` draft-filter orphan fix → Task 1. ✓
- No change to `PendingSend` → respected (no task touches it). ✓
- No commit-on-action → respected. ✓
- Testing: unit test for the filter (Task 1) + run-app manual (Task 2 Step 3) matching the spec's three scenarios. ✓

**Placeholder scan:** No TBD/TODO; all code blocks are complete and concrete. ✓

**Type consistency:** `Store.buildDraftFilter(TableInfo<Table, DataClass>)` defined in Task 1 Step 1 and used in Task 1 Step 2. `NoteCommands({note, showCommands, tileBg})` used as in the existing call site. `NoteReactionsCompanion`/`NotesCompanion` fields match the table mixins (`id`, `pending`, `updatedAt` default; notes need `createdAt`/`sourceCreatedAt`). ✓
