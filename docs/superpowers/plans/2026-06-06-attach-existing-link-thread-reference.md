# Attach existing items as thread references Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the note editor's "Add link" modal attach an existing reference (a `ThreadUserAction` for Plot threads, an `ExternalUserAction` for plain URLs) to the current note instead of navigating away, surface Plot threads via remote search, and remove the now-redundant "Create new …" connector flow.

**Architecture:** Pure client-side change in `apps/plot`. The link modal becomes a pure attach-an-existing-reference picker. Picking a Plot thread (or an existing link that belongs to a Plot thread) appends a `ThreadUserAction` to the note's `actions` list — which round-trips through sync unchanged (the server stores `note.actions` verbatim and enriches `type:"thread"` actions with fresh `title`/`priorityId` on pull). No DB migration, no server change.

**Tech Stack:** Flutter / Dart, drift store models, `SelectModal`, `flutter_test`.

---

## Background facts (verified)

- `ThreadUserAction` (`lib/store/user_action.dart:271`): `{String threadId, String? title, String? priorityId}`, `type: UserActionType.thread`. Renders via `ThreadLinkButton` (`lib/widget/note_action.dart:785`).
- `Thread` model: `Uuid get id` (`thread.id.toString()` → canonical UUID string), `String? get title`, `Priority get priority` (`thread.priority.id.toString()` → canonical priority UUID string). Confirmed usage in `lib/command/thread.dart:653,1658`.
- `Thread.searchRemote(String query, {required bool archived, PriorityId? priorityId, int limit = 50})` (`lib/store/thread.dart:7305`) returns `Future<List<Thread>>`; returns `[]` for empty query; hits `/sync/threads/search` and hydrates locally.
- `Link.threadId` is a nullable `Uuid`; `LinkModal` already resolves it to a `Thread` via `Thread.getOne(link.threadId!)`.
- Notes-only Plot threads have **no `Link` row**, so they only appear via `Thread.searchRemote`.
- Pure-helper-in-command-file + `flutter_test` is an established pattern (`shouldOpenChannelSetupAfterConnect` in `lib/command/twist.dart`, tested by `test/command/draft_handoff_test.dart`).

---

## File Structure

- **Modify** `lib/command/add_link.dart` — add a pure `appendThreadReference(...)` helper; rewrite `AddLink.run` to attach (thread → `ThreadUserAction`, dedup) instead of navigate; drop `onNavigateToThread` and the create-action branch.
- **Create** `test/command/add_link_test.dart` — unit tests for `appendThreadReference`.
- **Modify** `lib/widget/link_input.dart` — add a `Thread` variant to `_LinkItem` + thread search ("Threads" group) + itemBuilder case; remove all "Create new …" plumbing and the `LinkModalResult.create` variant.
- **Modify** `lib/widget/note_editor.dart` — remove `onNavigateToThread`; render `ThreadUserAction` in the attachment row with an "✕".
- **Modify** `lib/page/new_thread.dart` — remove the two `onNavigateToThread:` callbacks.
- **Modify** `lib/widget/connection_targets.dart` — delete `createTargetTile()` (modal-only); keep everything else.
- **Modify** `docs/updates.md` — one user-facing bullet.

---

## Task 1: Pure `appendThreadReference` helper + tests

**Files:**
- Modify: `lib/command/add_link.dart`
- Test: `test/command/add_link_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/command/add_link_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/add_link.dart';
import 'package:plot/store/store.dart';

void main() {
  group('appendThreadReference', () {
    test('appends a ThreadUserAction with the given fields', () {
      final result = appendThreadReference(
        const [],
        threadId: 't1',
        title: 'Quarterly plan',
        priorityId: 'p1',
      );

      expect(result, hasLength(1));
      final action = result.single as ThreadUserAction;
      expect(action.threadId, 't1');
      expect(action.title, 'Quarterly plan');
      expect(action.priorityId, 'p1');
    });

    test('preserves existing actions and appends at the end', () {
      const existing = ExternalUserAction(title: 'Doc', url: 'https://x.test');
      final result = appendThreadReference(
        const [existing],
        threadId: 't1',
        title: 'Plan',
        priorityId: 'p1',
      );

      expect(result, hasLength(2));
      expect(result.first, existing);
      expect((result.last as ThreadUserAction).threadId, 't1');
    });

    test('is a no-op when the same threadId is already attached', () {
      const existing = ThreadUserAction(threadId: 't1', title: 'Old');
      final result = appendThreadReference(
        const [existing],
        threadId: 't1',
        title: 'New title',
        priorityId: 'p1',
      );

      expect(result, hasLength(1));
      // Unchanged reference returned (no duplicate, no overwrite).
      expect(result.single, existing);
    });

    test('does not mutate the input list', () {
      final input = <UserAction>[];
      appendThreadReference(input, threadId: 't1', title: 'A', priorityId: 'p1');
      expect(input, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/command/add_link_test.dart`
Expected: FAIL — `appendThreadReference` is not defined.

- [ ] **Step 3: Add the helper to `add_link.dart`**

Add this top-level function at the end of `lib/command/add_link.dart` (after the `AddLink` class):

```dart
/// Returns a new actions list with a [ThreadUserAction] for [threadId]
/// appended. If a thread reference for [threadId] is already present, the
/// list is returned unchanged (no duplicate, existing reference preserved).
/// Does not mutate [current].
List<UserAction> appendThreadReference(
  List<UserAction> current, {
  required String threadId,
  String? title,
  String? priorityId,
}) {
  final alreadyAttached = current.any(
    (a) => a is ThreadUserAction && a.threadId == threadId,
  );
  if (alreadyAttached) return current;
  return [
    ...current,
    ThreadUserAction(threadId: threadId, title: title, priorityId: priorityId),
  ];
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/command/add_link_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/command/add_link.dart test/command/add_link_test.dart
git commit --no-verify -m "feat(compose): appendThreadReference helper for attaching thread refs"
```

---

## Task 2: Rewrite `AddLink.run` to attach instead of navigate

**Files:**
- Modify: `lib/command/add_link.dart`

This task changes `AddLink` to (a) drop `onNavigateToThread`, (b) drop the create-action branch, and (c) attach a `ThreadUserAction` when the result is a thread. The `LinkModalResult` API used here (`isThread`, `existingThread`, `isLink`, `url`, `title`, `favicon`) stays the same until Task 3 removes only the `create` members — `isThread`/`isLink` remain.

- [ ] **Step 1: Replace the `AddLink` class body**

In `lib/command/add_link.dart`, remove the `onNavigateToThread` field and constructor param, and rewrite `run`. The full class becomes:

```dart
class AddLink extends Command {
  AddLink({
    required this.currentActions,
    required this.onActionsChanged,
  }) : super(
         title: 'Add link',
         eventObject: EventObject.note,
         eventAction: EventAction.added,
         icon: PlotIcon.link,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyL,
           shift: true,
         ),
       );

  final List<UserAction> currentActions;
  final void Function(List<UserAction> actions) onActionsChanged;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await LinkModal.open(context);
    if (result == null) return const CommandSkipped();

    if (result.isThread) {
      // Attach a reference to the existing Plot thread instead of navigating
      // to it. Deduped by threadId so re-picking the same thread is a no-op.
      final thread = result.existingThread!;
      onActionsChanged(
        appendThreadReference(
          currentActions,
          threadId: thread.id.toString(),
          title: thread.title,
          priorityId: thread.priority.id.toString(),
        ),
      );
      return const CommandDone();
    }

    if (result.isLink) {
      final linkAction = ExternalUserAction(
        title: result.title ?? result.url!,
        url: result.url!,
        favicon: result.favicon,
      );
      onActionsChanged([...currentActions, linkAction]);
    }

    return const CommandDone();
  }
}
```

(Leave the `appendThreadReference` helper from Task 1 below the class.)

- [ ] **Step 2: Run the helper tests (still pass)**

Run: `flutter test test/command/add_link_test.dart`
Expected: PASS (4 tests) — the helper is unchanged.

- [ ] **Step 3: Analyze (will report the now-broken callers)**

Run: `flutter analyze lib/command/add_link.dart`
Expected: clean for `add_link.dart` itself. Callers (`note_editor.dart`, `new_thread.dart`) still pass `onNavigateToThread:` and will be fixed in Tasks 4–5; analyzing the whole app now would show those as errors — that is expected and resolved by Task 5.

- [ ] **Step 4: Commit**

```bash
git add lib/command/add_link.dart
git commit --no-verify -m "feat(compose): AddLink attaches thread reference instead of navigating"
```

---

## Task 3: `LinkModal` — surface Plot threads, remove "Create new …"

**Files:**
- Modify: `lib/widget/link_input.dart`

- [ ] **Step 1: Trim `LinkModalResult` to remove the create variant**

Replace the `LinkModalResult` class (top of `lib/widget/link_input.dart`) with:

```dart
/// Result from the link modal: an existing thread to attach as a reference,
/// or a plain URL link to attach.
class LinkModalResult {
  final String? url;
  final String? title;
  final String? favicon;
  final Thread? existingThread;

  LinkModalResult.link({
    required String this.url,
    this.title,
    this.favicon,
  }) : existingThread = null;

  LinkModalResult.thread(Thread this.existingThread)
      : url = null,
        title = null,
        favicon = null;

  bool get isThread => existingThread != null;
  bool get isLink => url != null;
}
```

- [ ] **Step 2: Replace the `_LinkItem` class — drop create-external, add thread**

Replace the `_LinkItem` class (bottom of the file) with:

```dart
/// Internal item type for the SelectModal.
class _LinkItem {
  final _LinkSearchResult? linkResult;
  final Thread? thread;
  final String? url;
  final String? title;
  final String? favicon;

  _LinkItem.existing(this.linkResult)
      : thread = null,
        url = null,
        title = null,
        favicon = null;

  _LinkItem.thread(this.thread)
      : linkResult = null,
        url = null,
        title = null,
        favicon = null;

  _LinkItem.create({required this.url, this.title, this.favicon})
      : linkResult = null,
        thread = null;

  bool get isThread => thread != null;
  bool get isCreate => linkResult == null && thread == null;
}
```

- [ ] **Step 3: Rewrite the `items` callback — drop create targets, add thread search**

Replace the entire `items:` callback passed to `SelectModal.open<_LinkItem>` with:

```dart
      items: (search) async {
        final text = search?.trim() ?? '';
        final groups = <SelectGroup<_LinkItem>>[];

        if (text.isEmpty) {
          final recentLinks = await Link.listRecent();
          if (recentLinks.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Recent',
              items: recentLinks
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
            ));
          }
          return groups;
        }

        final isUrl = _checkIsUrl(text);

        if (isUrl) {
          final links = await Link.findBySourceUrl(text);
          if (links.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: links
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
            ));
          } else {
            // Fetch metadata for the URL
            final metadata = await fetchUrlMetadata(text);
            fetchedTitle = metadata.title;
            fetchedFavicon = metadata.favicon;
            groups.add(SelectGroup(
              title: null,
              items: [
                _LinkItem.create(
                  url: text,
                  title: fetchedTitle,
                  favicon: fetchedFavicon,
                ),
              ],
            ));
          }
        } else {
          final links = await Link.searchByTitle(text);
          if (links.isNotEmpty) {
            groups.add(SelectGroup(
              title: null,
              items: links
                  .map((l) => _LinkItem.existing(_LinkSearchResult(link: l)))
                  .toList(),
            ));
          }

          // Surface Plot threads (incl. notes-only threads with no Link row),
          // which only appear via remote search. Network-backed; offline this
          // silently yields nothing. Network failures are expected here, so
          // swallow them rather than reporting to error tracking.
          List<Thread> threads = const [];
          try {
            threads = await Thread.searchRemote(text, archived: false);
          } catch (_) {
            threads = const [];
          }
          if (threads.isNotEmpty) {
            groups.add(SelectGroup(
              title: 'Threads',
              items: threads.map((t) => _LinkItem.thread(t)).toList(),
            ));
          }
        }

        return groups;
      },
```

Also delete the now-unused `createTargets` local declaration and its leading comment near the top of `LinkModal.open` (the `List<CreateTarget>? createTargets;` line).

- [ ] **Step 4: Rewrite the `itemBuilder` — drop createExternal, add thread**

Replace the `itemBuilder:` callback with:

```dart
      itemBuilder: (item, isLoading) {
        if (item.isThread) {
          return ListTile(
            icon: PlotIcon.inbox,
            title: item.thread!.title ?? 'Untitled',
          );
        }
        if (item.isCreate) {
          return ListTile(
            icon: item.favicon == null ? PlotIcon.add : null,
            leadingBuilder: item.favicon != null
                ? (_, _) => Builder(
                    builder: (context) => Padding(
                      padding: EdgeInsets.only(
                        left: context.theme.spacing.lg,
                        right: 8,
                      ),
                      child: LogoImage(
                        url: item.favicon!,
                        size: 16,
                        fallback: const Icon(PlotIcon.add, size: 16),
                      ),
                    ),
                  )
                : null,
            title: item.title ?? item.url!,
            subtitle: item.title != null ? item.url : null,
          );
        }

        final link = item.linkResult!.link;
        final logoUrl = link.logoForBrightness(Brightness.light);
        return ListTile(
          leadingBuilder: logoUrl != null
              ? (_, _) => Builder(
                  builder: (context) => Padding(
                    padding: EdgeInsets.only(
                      left: context.theme.spacing.lg,
                      right: 8,
                    ),
                    child: LogoImage(
                      url: logoUrl,
                      size: 16,
                      fallback: const Icon(PlotIcon.link, size: 16),
                    ),
                  ),
                )
              : null,
          icon: logoUrl == null ? PlotIcon.link : null,
          title: link.title ?? link.sourceUrl ?? 'Link',
        );
      },
```

- [ ] **Step 5: Rewrite the result-mapping block — drop create, add thread**

Replace the block after `if (!result.present) return null;` (the `final item = result.value;` through the final `return null;`) with:

```dart
    final item = result.value;
    if (item.isThread) {
      return LinkModalResult.thread(item.thread!);
    }
    if (item.isCreate) {
      return LinkModalResult.link(
        url: item.url!,
        title: item.title,
        favicon: item.favicon,
      );
    }

    final link = item.linkResult!.link;
    // Links that point at a Plot thread attach a reference to that thread;
    // resolve the Thread lazily here (instead of eagerly for every Recent row
    // at modal-open time) so the modal opens immediately. Fall through to the
    // URL form if the thread has been deleted locally.
    if (link.threadId != null) {
      try {
        final thread = await Thread.getOne(link.threadId!);
        return LinkModalResult.thread(thread);
      } catch (_) {
        // Thread not found — treat as a plain URL.
      }
    }
    if (link.sourceUrl != null) {
      return LinkModalResult.link(
        url: link.sourceUrl!,
        title: link.title,
        favicon: link.logo,
      );
    }

    return null;
```

- [ ] **Step 6: Remove the now-unused `createTargetTile` import usage**

`createTargetTile` and `CreateTarget` are no longer referenced in this file. Remove any import that exists **only** for them (check the import block — `connection_targets.dart` symbols). Keep imports still used (`store.dart`, `spacing.dart`, `url_title.dart`, `widget.dart`). If `connection_targets.dart` was imported via the barrel `widget.dart`, no import line changes are needed.

- [ ] **Step 7: Analyze the file**

Run: `flutter analyze lib/widget/link_input.dart`
Expected: no errors (warnings about unused `isLoading` parameter are pre-existing style, acceptable). If it reports an unused import, remove that import.

- [ ] **Step 8: Commit**

```bash
git add lib/widget/link_input.dart
git commit --no-verify -m "feat(compose): link modal surfaces Plot threads, drops Create-new flow"
```

---

## Task 4: `note_editor.dart` — drop navigate wiring, render thread attachments

**Files:**
- Modify: `lib/widget/note_editor.dart`

- [ ] **Step 1: Remove the `onNavigateToThread` field**

Search `lib/widget/note_editor.dart` for `onNavigateToThread`. Remove the field declaration and its constructor parameter (the `NoteEditor` widget's `this.onNavigateToThread` and `final void Function(Thread thread)? onNavigateToThread;`).

- [ ] **Step 2: Stop passing `onNavigateToThread` to `AddLink`**

Find the `AddLink(` construction (around line 1538) and remove the `onNavigateToThread: widget.onNavigateToThread,` argument. After the edit it reads:

```dart
              AddLink(
                currentActions: draftNote.actions ?? const [],
                onActionsChanged: (actions) {
                  widget.onDraftChanged!(
                    thread,
                    note: draftNote.copyWith(actions: actions),
                  );
                },
              ),
```

- [ ] **Step 3: Include thread actions in the attachment-row filter**

In `_buildAttachmentRows()` (around line 1136), add `UserActionType.thread` to the filter:

```dart
    final attachments = actions
        .where(
          (a) =>
              a.type == UserActionType.file ||
              a.type == UserActionType.external ||
              a.type == UserActionType.thread ||
              (a.type == UserActionType.createLink && !widget.isNewThreadMode),
        )
        .toList();
```

- [ ] **Step 4: Render the thread attachment row**

In `_buildAttachmentRow(UserAction action)` (around line 1165), add a `ThreadUserAction` branch alongside the existing `ExternalUserAction` branch. Change the `else if (action is ExternalUserAction) { … }` chain so it ends with a thread branch before the fallback `else`:

```dart
    } else if (action is ExternalUserAction) {
      final favicon = action.favicon;
      icon = favicon != null
          ? LogoImage(
              url: favicon,
              size: 12,
              fallback: Icon(
                PlotIcon.link,
                size: 12,
                color: context.colour.muted,
              ),
            )
          : Icon(PlotIcon.link, size: 12, color: context.colour.muted);
      label = action.title;
    } else if (action is ThreadUserAction) {
      icon = Icon(PlotIcon.inbox, size: 12, color: context.colour.muted);
      label = action.title ?? 'Thread';
    } else {
      return const SizedBox.shrink();
    }
```

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/widget/note_editor.dart`
Expected: no errors. (If it flags an unused `Thread` import that was only used by the removed field, remove that import.)

- [ ] **Step 6: Commit**

```bash
git add lib/widget/note_editor.dart
git commit --no-verify -m "feat(compose): render draft thread references; drop navigate-on-link wiring"
```

---

## Task 5: `new_thread.dart` — remove `onNavigateToThread` callbacks

**Files:**
- Modify: `lib/page/new_thread.dart`

- [ ] **Step 1: Remove both callbacks**

Search `lib/page/new_thread.dart` for `onNavigateToThread`. There are two `NoteEditor(...)` call sites (around lines 1690 and 1763) each passing:

```dart
              onNavigateToThread: (thread) {
                context.run(
                  ChangeCurrentThread(thread),
                );
              },
```

Remove both `onNavigateToThread:` arguments entirely.

- [ ] **Step 2: Remove a now-unused `ChangeCurrentThread` import if applicable**

Check whether `ChangeCurrentThread` is still referenced elsewhere in `new_thread.dart` (grep the file). If it is no longer used, remove its import; if still used, leave the import.

Run: `grep -n 'ChangeCurrentThread' lib/page/new_thread.dart`

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/page/new_thread.dart`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/page/new_thread.dart
git commit --no-verify -m "feat(compose): drop navigate-to-thread callback on new-thread editors"
```

---

## Task 6: Delete the modal-only `createTargetTile`

**Files:**
- Modify: `lib/widget/connection_targets.dart`

- [ ] **Step 1: Confirm no remaining callers**

Run: `grep -rn 'createTargetTile' lib/`
Expected: zero matches (Task 3 removed the only caller). If any remain, stop and fix the caller instead of deleting.

- [ ] **Step 2: Delete the `createTargetTile` function**

In `lib/widget/connection_targets.dart`, delete the entire `createTargetTile(...)` function (starts around line 328). **Do not** touch `CreateTarget`, `loadCreateTargets()`, `connectionTargetTile()`, or `CreateTarget.toUserAction()` — those remain in use by the NewThreadPage compose flow.

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/widget/connection_targets.dart`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/widget/connection_targets.dart
git commit --no-verify -m "refactor(compose): remove modal-only createTargetTile"
```

---

## Task 7: Full analyze, docs, and final verification

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Run the helper tests**

Run: `flutter test test/command/add_link_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 2: Full app analyze**

Run: `flutter analyze`
Expected: no new errors introduced by this change. (Info-level lints tolerated, matching CI's `--no-fatal-infos`.) Fix any errors that trace to the edited files — especially leftover unused imports or references to removed members (`onNavigateToThread`, `LinkModalResult.create`, `isCreateAction`, `createAction`, `createTargetTile`, `_LinkItem.createExternal`).

- [ ] **Step 3: Add a user-facing update note**

Add a bullet to the top section of `docs/updates.md`:

```markdown
- The link button in notes now lets you attach a reference to another Plot thread — including notes-only threads — instead of jumping away to it. Search by title to find any thread, or paste a URL as before.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.md
git commit --no-verify -m "docs: note attach-existing-thread-reference change"
```

---

## Self-review notes

- **Spec coverage:** behavior table → Tasks 2,3; surface Plot threads via search → Task 3 Step 3; remove "Create new …" → Task 3 (+ Task 6 deletes `createTargetTile`); attach as `ThreadUserAction` non-primary → Tasks 1,2,4; everywhere (no navigate) → Tasks 4,5; render + remove affordance → Task 4; keep shared `CreateTarget` infra → Task 6 Step 2.
- **Dedup:** enforced in `appendThreadReference` (Task 1) and exercised by tests.
- **Display redundancy (known, acceptable):** a connector-backed thread can appear both as a title-matched `Link` and under "Threads"; both attach the same `ThreadUserAction` (deduped at attach time). Not deduped in the picker for v1.
- **No FONT_CACHE bump:** reuses existing `PlotIcon.inbox` / `PlotIcon.link` glyphs; no new FontAwesome icon.
- **Type consistency:** `appendThreadReference(List<UserAction>, {required String threadId, String? title, String? priorityId})` used identically in Task 1 (def/tests) and Task 2 (call); `thread.id.toString()` / `thread.priority.id.toString()` / `thread.title` confirmed against `lib/store/thread.dart`.
