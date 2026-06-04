# Message-Sharing Thread Participants & Per-Message Recipient Changes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make message-sharing (email) threads show participant avatars in list rows and the header, default replies to the latest message's recipients (with an easy "In this thread" re-add), show per-message recipient-change feed lines, and delete the dead 50%/dropped-contacts machinery.

**Architecture:** The avatar overview reads `thread.contacts` (the synced union — already maintained monotonically by `user.upsert_thread`). Per-reply recipients are a note-level concern defaulting to the latest note's participants. The header is read-only; recipient editing lives only in the composer's Reply pill, whose picker gains an "In this thread" section. A feed-update line renders between consecutive notes whose audiences differ. No schema changes in v1.

**Tech Stack:** Dart/Flutter (`apps/plot`), TypeScript Cloudflare Workers (`workers/api`), Vitest (API unit tests). Flutter has no widget-test harness — verification is via the `run-app` skill. Spec: `docs/superpowers/specs/2026-06-04-message-sharing-participants-design.md`.

---

## Preconditions

- Execute in an isolated git worktree (the executing skill creates it). No database migration is needed — `thread.dropped_contacts` stays in place (unused); its removal is a tracked follow-up.
- Scope is `sharingModel == message` (email). Thread-mode and channel-mode paths must be left unchanged. Verify each Flutter change is gated on `SharingModel.message`.

## File map

| File | Task | Action |
|---|---|---|
| `workers/api/src/twist/tools/plot/link.ts` | 1 | Modify — delete message-mode reconciliation block + unused imports |
| `workers/api/src/twist/sharing.ts` | 1 | Modify — delete `reconcileThreadContacts` (keep `updateThreadDroppedContacts`) |
| `workers/api/src/twist/sharing.test.ts` | 1 | Delete |
| `apps/plot/lib/widget/thread.dart` | 2, 6 | Modify — avatar overview reads `thread.contacts`; message-mode header tap → read-only modal |
| `apps/plot/lib/store/thread.dart` | 2, 3, 5 | Modify — remove `deriveVisibleContacts`; add `latestNoteAudience`; replace `noteBadgeLabel` with `recipientChangeLabel` |
| `apps/plot/lib/widget/note_editor.dart` | 3 | Modify — reply default = latest note participants |
| `apps/plot/lib/state/thread.dart` | 3 | Modify — initialize message-mode reply draft to latest-note audience |
| `apps/plot/lib/command/share.dart` | 4 | Modify — add opt-in "In this thread" section to `buildSharedSelectionCommands` + `PickShared` |
| `apps/plot/lib/widget/recipient_picker_modal.dart` | 4 | Modify — pass thread union as the "In this thread" source |
| `apps/plot/lib/widget/recipient_change_line.dart` | 5 | Create — interstitial feed-update line widget |
| `apps/plot/lib/widget/note_badge.dart` | 5 | Delete |
| `apps/plot/lib/widget/note.dart` | 5 | Modify — render recipient-change line; drop `NoteBadge` |
| `apps/plot/lib/command/thread.dart` | 6 | Create — `PickThreadParticipants` read-only modal |
| `docs/updates.md` | 7 | Modify — user-facing note |

---

# Phase 1 — Server: delete the dead 50% / dropped-contacts machinery

`user.upsert_thread` already unions `v_existing.contacts || v_input_contacts` for attested callers (`libs/db/schema/90-user-schema/80-upsert_thread.sql:305-335`), so `thread.contacts` stays a monotonic union with no extra code. The only thing the `link.ts` reconciliation block did was write `dropped_contacts` (0 rows in prod). Delete it.

### Task 1: Remove `reconcileThreadContacts` and its only caller

**Files:**
- Modify: `workers/api/src/twist/tools/plot/link.ts:20-21,164-228`
- Modify: `workers/api/src/twist/sharing.ts:1-48`
- Delete: `workers/api/src/twist/sharing.test.ts`

- [ ] **Step 1: Delete the message-mode reconciliation block in `link.ts`**

Remove the entire comment+`if` block at `link.ts:164-228` (from the comment starting `// Message-mode contact reconciliation.` through the closing `}` of the `if (threadData.id && link.accessContacts !== undefined && link.accessContacts.length > 0) { ... }`). The next surviving line is the comment `// Pass skipNotify=true ...` (currently line 230) followed by `let { id: threadId, priorityId: threadPriorityId } = await createThread(plot, threadData, true);`.

- [ ] **Step 2: Remove now-unused imports in `link.ts`**

Line 20 is `import { getSharingModelForChannel } from "../../../app/sync/link-tags";` and line 21 is `import { reconcileThreadContacts, updateThreadDroppedContacts } from "../../sharing";`. Confirm none are used elsewhere in the file, then delete the unused ones:

```bash
cd /Users/kris.braun/code/plot
rg -n "getSharingModelForChannel|reconcileThreadContacts|updateThreadDroppedContacts|\baddContacts\b" workers/api/src/twist/tools/plot/link.ts
```

Expected after Step 1: `getSharingModelForChannel`, `reconcileThreadContacts`, and `updateThreadDroppedContacts` appear ONLY on the import lines (20-21) → delete both import lines. `addContacts` will still appear elsewhere → keep its import (it is imported separately). If any of the three still appears outside the imports, leave that import and note why.

- [ ] **Step 3: Delete `reconcileThreadContacts` from `sharing.ts`**

In `workers/api/src/twist/sharing.ts`, delete the doc comment + function spanning lines 4-48 (the `/** Reconcile ... */` block and `export function reconcileThreadContacts(...) { ... }`). Keep the `import { sql, type Kysely } from "kysely";` / `import type { DB } from "../db-types";` lines and the entire `updateThreadDroppedContacts` function (lines 50-75) — it is still used by `workers/api/src/app/thread-share.ts`.

After editing, the file starts with the two imports, then the `updateThreadDroppedContacts` doc comment and function.

- [ ] **Step 4: Delete the obsolete test file**

```bash
cd /Users/kris.braun/code/plot
git rm workers/api/src/twist/sharing.test.ts
```

`sharing.test.ts` only tested `reconcileThreadContacts`, so the whole file goes.

- [ ] **Step 5: Verify the API unit tests + type-check pass**

```bash
cd /Users/kris.braun/code/plot/workers/api
timeout 300 pnpm test
pnpm lint
```

Expected: `pnpm test` passes (no reference to the deleted file/function). `pnpm lint` shows **no new** `error TS` lines (main has 2 pre-existing unrelated errors — Uint8Array/BlobPart; the gate is "no new errors", not exit 0). If `tsc` reports an unused import or missing symbol in `link.ts`/`sharing.ts`, fix it per Steps 2-3.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add workers/api/src/twist/tools/plot/link.ts workers/api/src/twist/sharing.ts
git commit -m "api: drop dead 50% reconciliation (thread.contacts already unions in upsert_thread)" -- workers/api/src/twist/tools/plot/link.ts workers/api/src/twist/sharing.ts workers/api/src/twist/sharing.test.ts
```

---

# Phase 2 — Avatar overview reads `thread.contacts` (the bug fix)

### Task 2: Render message-mode avatars from `thread.contacts`

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart:1021-1069`
- Modify: `apps/plot/lib/store/thread.dart` (delete `deriveVisibleContacts`, ~4752-4771)

- [ ] **Step 1: Replace the per-viewer derivation with a direct `thread.contacts` read**

In `apps/plot/lib/widget/thread.dart`, replace the block currently at lines 1021-1069 (from the comment `// Message-mode: derive visible contacts per-viewer ...` through the `final actors = loadedActors ?? (...)` assignment) with:

```dart
    // Avatar overview reads thread.contacts directly — the synced union of
    // everyone ever on the thread — for every sharing model. thread.contacts
    // is always present on the thread row, so list rows and the first-paint
    // header populate even before notes load. Hidden-role (BCC) contacts are
    // stripped per-viewer server-side, so this never leaks.
    final contactsKey = thread.contacts.map((u) => u.toString()).join('|');
    final loadedActors = useFuture(
      useMemoized(() => command.loadSharedDisplayActors(), [contactsKey]),
    ).data;
    final actors = loadedActors ?? command.sharedDisplayActors;
```

This drops the `viewerContactIds`, `visibleContactIds`, and `Thread.deriveVisibleContacts` usage. `sharingModel` is still used below (channel title + onPress), so leave it.

- [ ] **Step 2: Delete the now-unused `Thread.deriveVisibleContacts`**

Confirm it has no other callers, then remove it from `apps/plot/lib/store/thread.dart`:

```bash
cd /Users/kris.braun/code/plot/apps/plot
rg -n "deriveVisibleContacts" lib
```

Expected: only the definition in `lib/store/thread.dart` (no other call sites after Step 1). Delete the `deriveVisibleContacts` static method and its doc comment (currently ~4752-4771, the `/// Per-viewer visible-contacts derivation ... static Set<Uuid> deriveVisibleContacts({ ... }) { ... }`).

- [ ] **Step 3: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/widget/thread.dart lib/store/thread.dart
```

Expected: no new errors. (`flutter analyze --no-fatal-infos` is the CI gate — info-level lints are tolerated.)

- [ ] **Step 4: Manual verification (`run-app` skill)**

Open the Gmail example thread (`https://app.plot.day/t/Cb4dQ8PbTozvstYETvSUx`, or any email thread) in the agent profile:
- **List row** for the thread shows participant avatars (2 for the example: the two external participants; self is excluded). Previously empty.
- **Thread header** shows the same avatars immediately on open (no empty first paint).
- A non-email **Slack DM / calendar** thread still shows its avatars (thread-mode unchanged); a **Slack channel** still shows its channel title (channel-mode unchanged).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/thread.dart apps/plot/lib/store/thread.dart
git commit -m "app: render message-mode thread avatars from thread.contacts (fixes empty list/header avatars)" --no-verify
```

(`--no-verify`: the husky pre-commit hook needs `pnpm install`, which a Flutter-only worktree skips. Dart-only commits use `--no-verify`; analyze in Step 3 is the gate.)

---

# Phase 3 — Reply default = latest message's participants

### Task 3a: Add `Thread.latestNoteAudience` helper

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (add near the former `deriveVisibleContacts` site)

- [ ] **Step 1: Add the static helper**

In `apps/plot/lib/store/thread.dart`, add:

```dart
  /// Participants of the most recent note (its author + access_contacts).
  /// Used as the default reply audience for message-mode threads — "a
  /// reasonable assumption of the recipients at that point in the thread."
  /// Returns an empty set when there are no notes (callers fall back to
  /// thread.contacts). Order is not significant; callers dedupe.
  static Set<ActorId> latestNoteAudience(List<Note> notes) {
    if (notes.isEmpty) return const {};
    final latest = notes.reduce(
      (a, b) => b.sourceCreatedAt.isAfter(a.sourceCreatedAt) ? b : a,
    );
    return {
      latest.authorId,
      ...?latest.accessContacts,
    };
  }
```

- [ ] **Step 2: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/store/thread.dart
```

Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/store/thread.dart
git commit -m "app: add Thread.latestNoteAudience (default reply audience for message mode)" --no-verify
```

### Task 3b: Default the reply pill + draft to the latest note's audience

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart:768-781,884,917,959,1053-1055`
- Modify: `apps/plot/lib/state/thread.dart:404-411`

- [ ] **Step 1: Make `_replyAudience` mode-aware**

In `apps/plot/lib/widget/note_editor.dart`, replace the `_replyAudience` method (lines 768-781) with a version that takes the full state and, for message-mode, derives from the latest note:

```dart
  ({List<Actor> actors, int total}) _replyAudience(ThreadState s) {
    final base = s.primaryLinkTypeConfig?.sharingModel == SharingModel.message
        ? () {
            final audience = Thread.latestNoteAudience(s.notes)
                .map((a) => a.toUuid())
                .toList();
            return audience.isEmpty ? s.thread.activeContacts : audience;
          }()
        : s.thread.activeContacts;
    final nonSelf = base.where((c) => !_isSelfContact(c)).toList();
    final total = nonSelf.length + s.thread.groups.length;
    if (total < 2) return (actors: const [], total: 0);
    _warmAvatarCache(nonSelf);
    final actors = <Actor>[];
    for (final c in nonSelf) {
      final a = Actor.fromCache(ActorId.fromUuid(c));
      if (a != null) actors.add(a);
    }
    return (actors: actors, total: total);
  }
```

- [ ] **Step 2: Update the three `_replyAudience` call sites**

In `_buildPills`, change every `_replyAudience(s.thread)` to `_replyAudience(s)`. There are three (the mentionable-twist branch ~line 884, the shared-Plot-thread branch ~line 917, and the connector message-mode branch ~line 959):

```bash
cd /Users/kris.braun/code/plot/apps/plot
rg -n "_replyAudience\(s.thread\)" lib/widget/note_editor.dart
```

Replace each `_replyAudience(s.thread)` with `_replyAudience(s)`.

- [ ] **Step 3: Make the message-mode reply activation set the default audience**

`_activateConnectorReply` (lines 1053-1055) is used by both message-mode replies and channel/thread comments. Branch it so message-mode sets the latest-note audience instead of clearing to the whole-thread default:

```dart
  void _activateConnectorReply() {
    final bloc = context.read<ThreadBloc>();
    final s = bloc.state;
    if (s.primaryLinkTypeConfig?.sharingModel == SharingModel.message) {
      final audience = Thread.latestNoteAudience(s.notes);
      if (audience.isNotEmpty) {
        bloc.setDraftRecipients(
          accessContacts: {Base.actorId, ...audience}.toList(),
          accessGroups: const [],
        );
        return;
      }
    }
    bloc.updateDraft(_draftAsThreadDefault());
  }
```

- [ ] **Step 4: Initialize a fresh message-mode draft to the latest-note audience**

In `apps/plot/lib/state/thread.dart`, replace `_loadDraftNote` (lines 404-411) with:

```dart
  /// Loads draft note from database for the current thread
  Future<void> _loadDraftNote() async {
    final existingDraft = await Note.getDraftByActivity(state.thread.id);
    if (existingDraft != null) {
      emit(state.copyWith(draft: existingDraft));
      return;
    }
    // Message-mode: a fresh reply defaults to the latest note's participants
    // ("reasonable assumption at that point in the thread") so an un-edited
    // reply sends to the right audience. Falls through to the private-default
    // logic when there are no notes yet.
    if (Thread.resolveSharingModel(state.links) == SharingModel.message) {
      final notes = state.notes.isNotEmpty
          ? state.notes
          : await Note.getForThread(state.thread.id);
      final audience = Thread.latestNoteAudience(notes);
      if (audience.isNotEmpty) {
        emit(state.copyWith(
          draft: state.draft.copyWith(
            accessContacts: Value({Base.actorId, ...audience}.toList()),
          ),
        ));
        return;
      }
    }
    await _defaultDraftToPrivateIfViewers();
  }
```

Confirm `Value` is already imported in this file (it is used elsewhere in the bloc, e.g. `editNoteRecipients`). If `Base` is not imported, add the existing import used elsewhere for `Base.actorId`.

- [ ] **Step 5: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/widget/note_editor.dart lib/state/thread.dart
```

Expected: no new errors.

- [ ] **Step 6: Manual verification (`run-app` skill)**

On a Gmail thread whose latest message went to fewer people than the full roster:
- The composer's **Reply pill** avatars show the latest message's participants (not the full union).
- Opening the recipient picker (tap the Reply pill avatars) shows those same people pre-selected.
- The header avatar overview still shows the **full** union (Task 2) — confirm the two intentionally differ.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/note_editor.dart apps/plot/lib/state/thread.dart
git commit -m "app: default message-mode replies to the latest message's participants" --no-verify
```

---

# Phase 4 — "In this thread" re-add section in the reply picker

### Task 4: Add an opt-in "In this thread" group to the share picker

**Files:**
- Modify: `apps/plot/lib/command/share.dart:174-254` (and `PickShared` factory ~463-500)
- Modify: `apps/plot/lib/widget/recipient_picker_modal.dart:142-174`

- [ ] **Step 1: Extend `buildSharedSelectionCommands` with the new params + section**

In `apps/plot/lib/command/share.dart`, change the `buildSharedSelectionCommands` signature (lines 174-180) to add three optional params:

```dart
Future<Commands> buildSharedSelectionCommands({
  required SharedSelection selection,
  required Future<void> Function(SharedSelection) onUpdate,
  required ShareCandidatesCache candidates,
  Priority? priority,
  bool injectSelf = false,
  List<Uuid> threadMemberIds = const [],
  String sharedSectionTitle = 'Shared',
  String threadSectionTitle = 'In this thread',
}) async {
```

After the `final sharedActorIds = sharedActors.map((a) => a.id).toList();` line (currently 217), add resolution of the "In this thread" actors:

```dart
  // "In this thread" section source: thread members (the union) who aren't
  // already selected and aren't self. One tap re-adds them to this reply.
  final inThreadActors = <Actor>[];
  if (threadMemberIds.isNotEmpty) {
    final selectedSet = sharedActorIds.toSet();
    final seenInThread = <ActorId>{};
    for (final contactId in threadMemberIds) {
      try {
        final actor = await Actor.getOne(ActorId.fromUuid(contactId));
        if (actor.self) continue; // self lives in the selected section
        if (selectedSet.contains(actor.id)) continue; // already selected
        if (seenInThread.add(actor.id)) inThreadActors.add(actor);
      } catch (_) {
        // Skip unresolvable contacts.
      }
    }
  }
  final inThreadActorIds = inThreadActors.map((a) => a.id).toList();
```

Then replace the returned `Commands(... groups: [...])` (lines 228-253) with:

```dart
  return Commands(
    prompt: 'Share with contact or email',
    emptyMessage: 'Enter an email address to invite someone',
    groups: [
      if (sharedActors.isNotEmpty ||
          sharedGroups.isNotEmpty ||
          selection.inviteEmails.isNotEmpty)
        StaticCommandGroup(
          title: sharedSectionTitle,
          commands: [
            ...sharedGroups.map(toggleGroup),
            ...sharedActors.map(toggleActor),
            ...selection.inviteEmails.map(toggleInvite),
          ],
        ),
      if (inThreadActors.isNotEmpty)
        StaticCommandGroup(
          title: threadSectionTitle,
          commands: inThreadActors.map(toggleActor).toList(),
        ),
      _SelectionShareSuggestionsGroup(
        selection: selection,
        excludeActorIds: [...sharedActorIds, ...inThreadActorIds],
        excludeGroupIds: selection.groups.toSet(),
        onUpdate: onUpdate,
        candidates: candidates,
        priority: priority,
        title: 'Share with',
      ),
    ],
  );
```

- [ ] **Step 2: Forward the new params through `PickShared`**

Read the `PickShared` factory (starts at line 463). Add `List<Uuid> threadMemberIds = const []`, `String sharedSectionTitle = 'Shared'`, and `String threadSectionTitle = 'In this thread'` to its parameter list, and pass them through to the `buildSharedSelectionCommands(...)` call inside its `commandsBuilder`. (The factory already forwards `selection`, `onUpdate`, `priority`, `injectSelf`; add the three new args alongside.)

- [ ] **Step 3: Pass the thread union from `RecipientPickerModal`**

In `apps/plot/lib/widget/recipient_picker_modal.dart`, the `run` method (lines 142-174) calls `PickShared(selection:, title: 'Recipients', injectSelf: true, onUpdate:)`. Add the thread-member source and the section title:

```dart
    await PickShared(
      selection: selection,
      title: 'Recipients',
      injectSelf: true,
      threadMemberIds: threadContacts.map(Uuid.fromString).toList(),
      sharedSectionTitle: 'Recipients',
      onUpdate: (next) async {
        selection = next;
        changed = true;
      },
    ).run(context);
```

`threadContacts` is already a constructor field on `RecipientPickerModal` (the full thread roster string ids passed by `_openRecipientPicker`). Note: `_openRecipientPicker` currently passes `s.thread.activeContacts` as `threadContacts`; since `dropped_contacts` is always empty, `activeContacts == contacts`, so this is the full union — no change needed there.

- [ ] **Step 4: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/command/share.dart lib/widget/recipient_picker_modal.dart
```

Expected: no new errors.

- [ ] **Step 5: Manual verification (`run-app` skill)**

On a Gmail thread where the latest message went to a subset of the roster, open the Reply pill's recipient picker:
- **Recipients** section: the latest-message participants (pre-selected default from Task 3).
- **In this thread** section: the roster members NOT on the last message — one tap re-adds them to the reply.
- **Share with** section: general suggestions, with both the above filtered out. Typing a new email still offers "Invite …".

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/share.dart apps/plot/lib/widget/recipient_picker_modal.dart
git commit -m "app: add 'In this thread' re-add section to the reply recipient picker" --no-verify
```

---

# Phase 5 — Per-message recipient-change feed line

### Task 5a: Replace `noteBadgeLabel` with `recipientChangeLabel`

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (replace `noteBadgeLabel`, ~4782-…)

- [ ] **Step 1: Replace the helper**

In `apps/plot/lib/store/thread.dart`, delete the `noteBadgeLabel` static method (its doc comment + body) and add in its place:

```dart
  /// Label for the per-message recipient-change feed line in a message-mode
  /// thread. Compares this note's audience to the previous note's audience and
  /// describes the membership delta from the reader's perspective. Returns
  /// null when nothing changed (no line). Self (the viewer's contacts) is
  /// excluded from named lists. v1 covers membership changes only — role
  /// transitions ("Sam to BCC") are a tracked follow-up.
  static String? recipientChangeLabel({
    required Set<Uuid> previous,
    required Set<Uuid> current,
    required Set<Uuid> viewerContactIds,
    required String Function(Uuid) nameLookup,
  }) {
    final added = current.difference(previous).difference(viewerContactIds);
    final removed = previous.difference(current).difference(viewerContactIds);
    if (added.isEmpty && removed.isEmpty) return null;

    final currentOthers = current.difference(viewerContactIds);

    String names(Iterable<Uuid> ids) {
      final list = ids.map(nameLookup).toList();
      if (list.length == 1) return list[0];
      if (list.length == 2) return '${list[0]} and ${list[1]}';
      if (list.length == 3) return '${list[0]}, ${list[1]} and ${list[2]}';
      return '${list[0]}, ${list[1]} +${list.length - 2}';
    }

    if (removed.isNotEmpty && added.isEmpty) {
      if (currentOthers.length == 1 && removed.length >= 2) {
        return 'Dropped everyone except ${names(currentOthers)}';
      }
      return 'Dropped ${names(removed)}';
    }
    if (added.isNotEmpty && removed.isEmpty) {
      return 'Added ${names(added)}';
    }
    return 'Added ${names(added)}, dropped ${names(removed)}';
  }
```

- [ ] **Step 2: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/store/thread.dart
```

Expected: errors only in `lib/widget/note.dart` (which still calls the now-deleted `noteBadgeLabel`) — fixed in Task 5c. `thread.dart` itself should be clean. If `thread.dart` reports the unused-method or other errors, fix them.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/store/thread.dart
git commit -m "app: replace noteBadgeLabel with recipientChangeLabel (membership-delta phrasing)" --no-verify
```

### Task 5b: Create the `RecipientChangeLine` widget

**Files:**
- Create: `apps/plot/lib/widget/recipient_change_line.dart`

- [ ] **Step 1: Write the widget**

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Interstitial "feed update" line shown between two consecutive notes in a
/// message-sharing thread when the recipient set changed (e.g. "Added Jamie",
/// "Dropped everyone except Paul"). Styled as a feed event: right-aligned,
/// author-name text size, muted, with equal vertical spacing above and below
/// so it reads as an event between the notes rather than a badge on one.
class RecipientChangeLine extends StatelessWidget {
  const RecipientChangeLine({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: context.theme.typography.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}
```

(`typography.sm` approximates the author-name size; if the note author label uses a different token, match it.)

- [ ] **Step 2: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/widget/recipient_change_line.dart
```

Expected: no errors.

### Task 5c: Render the line in `note.dart`; delete `NoteBadge`

**Files:**
- Modify: `apps/plot/lib/widget/note.dart:155-186`
- Delete: `apps/plot/lib/widget/note_badge.dart`

- [ ] **Step 1: Replace the badge computation with a recipient-change computation**

In `apps/plot/lib/widget/note.dart` `build` (the block currently ~155-174 that computes `badgeLabel` via `Thread.noteBadgeLabel`), replace it with a comparison against the chronologically-previous note:

```dart
    // Per-message recipient-change line for message-mode threads. Compare this
    // note's audience to the chronologically-previous note's. Order-independent
    // (sorts by sourceCreatedAt) so it doesn't depend on the list's order.
    final threadState = activityBloc.state;
    final sharingModel = Thread.resolveSharingModel(threadState.links);
    String? changeLabel;
    if (sharingModel == SharingModel.message) {
      final ordered = [...threadState.notes]
        ..sort((a, b) => a.sourceCreatedAt.compareTo(b.sourceCreatedAt));
      final idx = ordered.indexWhere((n) => n.id == widget.note.id);
      final prev = idx > 0 ? ordered[idx - 1] : null;
      if (prev != null) {
        Set<Uuid> audience(Note n) => <Uuid>{
              n.authorId.value,
              ...?n.accessContacts?.map((a) => a.value),
            };
        changeLabel = Thread.recipientChangeLabel(
          previous: audience(prev),
          current: audience(widget.note),
          viewerContactIds:
              Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet(),
          nameLookup: (id) =>
              Actor.fromCache(ActorId.fromUuid(id))?.nameOrEmail ?? 'Someone',
        );
      }
    }
```

- [ ] **Step 2: Render the line instead of the badge**

In the `bodyBuilder` `Column` (currently ~179-186), replace the `if (badgeLabel != null) ...[ Padding( ... child: NoteBadge(label: badgeLabel) ) ]` block with:

```dart
          if (changeLabel != null) RecipientChangeLine(label: changeLabel),
```

(Place it as the first child of the Column, where the badge was. The `RecipientChangeLine` already carries its own padding, so drop the wrapping `Padding`/`SizedBox` the badge used.)

- [ ] **Step 3: Fix imports**

In `note.dart`, remove `import 'package:plot/widget/note_badge.dart';` and add `import 'package:plot/widget/recipient_change_line.dart';` (match the file's existing import style/grouping).

- [ ] **Step 4: Delete `note_badge.dart`**

```bash
cd /Users/kris.braun/code/plot
rg -n "NoteBadge|note_badge" apps/plot/lib
```

Expected: no remaining references after Steps 1-3. Then:

```bash
git rm apps/plot/lib/widget/note_badge.dart
```

- [ ] **Step 5: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/widget/note.dart lib/widget/recipient_change_line.dart lib/store/thread.dart
```

Expected: no new errors.

- [ ] **Step 6: Manual verification (`run-app` skill)**

On a Gmail thread with messages that changed recipients mid-thread:
- A message whose recipients differ from the one before it shows a right-aligned feed line ("Added …", "Dropped …", or "Dropped everyone except …").
- Consecutive messages with the same recipients show **no** line.
- The first message shows no line.
- A non-email thread shows no lines anywhere.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/note.dart apps/plot/lib/widget/recipient_change_line.dart
git commit -m "app: show per-message recipient-change feed line in message-mode threads" --no-verify
```

---

# Phase 6 — Read-only header overview

### Task 6: Header avatar tap opens a read-only participants list

**Files:**
- Create command: `apps/plot/lib/command/thread.dart` (add `PickThreadParticipants`)
- Modify: `apps/plot/lib/widget/thread.dart:1185-1189`

- [ ] **Step 1: Add a read-only participants command**

In `apps/plot/lib/command/thread.dart`, add a `ShowCommands` factory that lists the thread's participants as non-actionable rows, plus a private display-row `Command`. Place it near `PickThreadShared` and mirror its imports.

```dart
/// Read-only "People on this thread" overview for message-mode threads. The
/// header avatar group opens this instead of the editable PickThreadShared:
/// in message-mode the roster is an auto-maintained union, so there's nothing
/// to edit here — recipients are chosen per-reply in the composer.
class PickThreadParticipants extends ShowCommands {
  PickThreadParticipants(Thread thread)
      : super(
          title: 'People on this thread',
          icon: PlotIcon.users,
          commandsBuilder: (context) async {
            final meta = thread.contactMeta;
            final rows = <Command>[];
            final seen = <ActorId>{};
            for (final contactId in thread.contacts) {
              try {
                final actor = await Actor.getOne(ActorId.fromUuid(contactId));
                if (!seen.add(actor.id)) continue;
                final role = (meta[contactId.toString()]
                    as Map<String, dynamic>?)?['role'] as String?;
                rows.add(_ThreadParticipantRow(actor, roleLabel: role));
              } catch (_) {
                // Skip unresolvable contacts.
              }
            }
            return Commands(
              prompt: 'People on this thread',
              emptyMessage: 'No participants',
              groups: [
                StaticCommandGroup(title: 'People on this thread', commands: rows),
              ],
            );
          },
        );
}

/// Non-actionable participant row: shows an avatar + name (+ role for the
/// privileged viewer). Tapping is a no-op — this list is read-only.
class _ThreadParticipantRow extends Command {
  _ThreadParticipantRow(this.actor, {this.roleLabel})
      : super(
          title: actor.nameOrEmail,
          subtitle: roleLabel,
          eventObject: EventObject.activity,
          eventAction: EventAction.opened,
        );

  final Actor actor;
  final String? roleLabel;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(actor: actor);

  @override
  Future<CommandReturn> run(BuildContext context) async => const CommandDone();
}
```

Confirm `Avatar`, `PlotIcon`, `EventObject`, `EventAction`, `CommandDone`, `ShowCommands`, `Commands`, `StaticCommandGroup` are already imported in `command/thread.dart` (they are used by the existing share commands). Add any missing import to match the file's style. If `contactMeta` values aren't `Map<String, dynamic>`, adjust the cast to match `Thread.contactMeta`'s shape.

- [ ] **Step 2: Route the message-mode header tap to it**

In `apps/plot/lib/widget/thread.dart`, the `onPress` ternary (lines 1185-1189) currently is:

```dart
      onPress: assignmentLink != null
          ? () => pickLinkAssignee(context, assignmentLink)
          : (sharingModel == SharingModel.channel && channelTitle != null)
          ? null
          : () => context.run(command),
```

Change the final branch so message-mode opens the read-only overview instead of the editable `PickThreadShared`:

```dart
      onPress: assignmentLink != null
          ? () => pickLinkAssignee(context, assignmentLink)
          : (sharingModel == SharingModel.channel && channelTitle != null)
          ? null
          : sharingModel == SharingModel.message
          ? () => context.run(PickThreadParticipants(thread))
          : () => context.run(command),
```

`command` (the `PickThreadShared(thread)` at line 951) stays for thread-mode.

- [ ] **Step 3: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze lib/command/thread.dart lib/widget/thread.dart
```

Expected: no new errors.

- [ ] **Step 4: Manual verification (`run-app` skill)**

- On a Gmail thread, tap the header avatar group → a read-only "People on this thread" list opens (avatars + names; no add/remove/toggle affordance; Esc closes).
- On a thread-mode thread (Slack DM / calendar), tapping the header still opens the editable share picker (unchanged).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/thread.dart apps/plot/lib/widget/thread.dart
git commit -m "app: message-mode header avatar opens a read-only participants overview" --no-verify
```

---

# Phase 7 — Finalize

### Task 7: Full analyze, docs, and finalize

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing update note**

At the top section of `docs/updates.md`, add (plain language, no jargon):

```markdown
- Email threads now show everyone who's been on the conversation in the thread list and header, default replies to the people on the latest message (with a quick way to re-add anyone else on the thread), and mark where the recipient list changed.
```

- [ ] **Step 2: Run the full app analyze (the CI gate)**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze --no-fatal-infos
```

Expected: no error-level findings. Investigate any new error; info/warning that pre-existed is tolerated.

- [ ] **Step 3: Run the finalize checklist**

Invoke the `/finalize` skill (lint changed packages, backwards-compat, error capture, docs, public submodule). This change touches no `public/` submodule files and no Twister types, so no changeset is needed. Confirm: no new `catch` blocks were added without `captureException` (this plan added none).

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs: note message-sharing participant + reply-default changes" --no-verify
```

---

## Self-review notes (coverage vs spec)

- **§1 data model / monotonic union** → Task 1 (delete dead 50%; union preserved by `upsert_thread`).
- **§2 avatar overview (Goal 1, the bug)** → Task 2.
- **§3 reply default (Goal 2)** → Tasks 3a/3b.
- **§3a "In this thread" re-add (Goal 3)** → Task 4.
- **§4 header read-only** → Task 6.
- **§5 per-message recipient-change line (Goal 4)** → Tasks 5a/5b/5c.
- **§6 cleanup** → Task 1 (server), Task 2 (`deriveVisibleContacts`), Task 5 (`NoteBadge`/`noteBadgeLabel`).
- **Deferred (out of scope, per spec):** role-transition deltas; `dropped_contacts` contract migration.

## Follow-ups (out of scope)

1. **Role-transition deltas** ("Sam to BCC") — needs per-note recipient-role storage.
2. **Contract migration** dropping `thread.dropped_contacts` and the Dart `droppedContacts` / `activeContacts` accessors once shipped.
3. **Delta-line phrasing tuning** with real usage (the "Dropped everyone except X" threshold, truncation counts, author-name text token).
