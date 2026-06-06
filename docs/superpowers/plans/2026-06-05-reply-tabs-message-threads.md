# Reply tabs for message threads + simplified Plot threads — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the avatar cluster on note-editor reply pills with a labeled "Reply all" tab (replyAll icon + count pill + edit pencil) and a narrow "Reply" tab for connector message threads, and simplify link-less Plot/twist threads to a single chat-like "Reply" + "Private note".

**Architecture:** Pure-presentation `TopBarPill`/`_Pill` in `note_editor_top_bar.dart` gains a leading icon, a recipient-count pill, and a tappable edit affordance (pencil/user-plus) with a tooltip, replacing the `AvatarGroup`. `note_editor.dart`'s `_buildPills` decides per thread type which fields to set. The recipient picker's prompt becomes "Select recipients". Contact-role editing is explicitly deferred (needs backend per-note role storage).

**Tech Stack:** Flutter (`flutter/widgets.dart` + `forui/forui.dart` only, never `material.dart`), Font Awesome icons, forui `FTooltip`. Spec: `docs/superpowers/specs/2026-06-05-reply-tabs-message-threads-design.md`.

**Pre-req:** Implement in an isolated git worktree (the working tree on `main` has unrelated in-progress changes to `apps/plot/lib/widget/compose/*`). Flutter-only change — no DB/worker work. To run `flutter test` in a worktree, the bootstrap is `flutter pub get` + `flutter pub run build_runner build` + copy `app.env` from main (see project memory "Worktree Flutter test bootstrap"). Dart-only commits in a Flutter-only worktree need `git commit --no-verify` (husky aborts otherwise).

---

## File structure

- **Modify** `apps/plot/lib/widget/note_editor_top_bar.dart` — `TopBarPill` model (swap avatar fields for `leadingIcon`/`recipientCount`/`editIcon`/`editTooltip`/`onEdit`); `_Pill` rendering; new private `_EditAffordance` widget; drop the `avatar.dart`/`store.dart` imports once unused.
- **Modify** `apps/plot/test/widget/note_editor_top_bar_test.dart` — update the `pill()` helper signature usage (it already only passes id/label/onTap, so it stays valid) and add tests for the new affordance.
- **Modify** `apps/plot/lib/widget/note_editor.dart` — `_buildPills` for the three thread types; remove the now-unused `_singleAvatar` helper.
- **Modify** `apps/plot/lib/command/share.dart` — thread a `prompt` parameter through `PickShared` → `buildSharedSelectionCommands`.
- **Modify** `apps/plot/lib/widget/recipient_picker_modal.dart` — pass `prompt: 'Select recipients'`.
- **Modify** `apps/plot/scripts/cache-bust-fonts.sh` — bump `FONT_CACHE_VERSION` (new `replyAll` glyph).

Verified facts used below:
- `FontAwesomeIcons.replyAll` exists (`font_awesome_flutter-10.12.0`).
- `PlotIcon.edit == FontAwesomeIcons.pen`; `PlotIcon.share == FontAwesomeIcons.userPlus` (`apps/plot/lib/widget/icon.dart:16,178`).
- `note_editor.dart` already imports `font_awesome_flutter` and uses `PlotIcon`.
- The only `TopBarPill(...)` construction sites are in `note_editor.dart` and the test file; `avatarActors`/`avatarTotalCount`/`onAvatarsTap` are referenced only in `note_editor.dart` and `note_editor_top_bar.dart`.
- Current `FONT_CACHE_VERSION=15` (`apps/plot/scripts/cache-bust-fonts.sh:42`).

---

## Task 1: Rework `TopBarPill` model + `_Pill` rendering + `_EditAffordance`

**Files:**
- Modify: `apps/plot/lib/widget/note_editor_top_bar.dart`
- Test: `apps/plot/test/widget/note_editor_top_bar_test.dart`

- [ ] **Step 1a: Make the test `host()` provide an `Overlay`**

`_EditAffordance` wraps its content in an `FTooltip`, which uses `OverlayPortal` and therefore needs an `Overlay` ancestor. The current `host()` helper has none. Replace the existing `host()` in `apps/plot/test/widget/note_editor_top_bar_test.dart` with:

```dart
  Widget host(Widget child) => FTheme(
        data: FThemes.zinc.light.desktop,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: [OverlayEntry(builder: (_) => child)],
          ),
        ),
      );
```

(`Overlay`/`OverlayEntry` come from the already-imported `flutter/widgets.dart`. This keeps the existing tests passing — they still find their text/icons — and lets the tooltip build.)

- [ ] **Step 1b: Write the failing tests**

Add these test groups to `apps/plot/test/widget/note_editor_top_bar_test.dart` (inside `main()`, after the existing `PillRowState` group). They reference the new fields/behaviour:

```dart
  group('NoteEditorTopBar — pill affordances', () {
    testWidgets('renders leading icon and recipient count pill', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            TopBarPill(
              id: 'reply',
              label: 'Reply all',
              leadingIcon: FontAwesomeIcons.replyAll,
              recipientCount: 3,
              editIcon: FontAwesomeIcons.pen,
              editTooltip: 'Edit recipients',
              onTap: () {},
              onEdit: () {},
            ),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.byIcon(FontAwesomeIcons.replyAll), findsOneWidget);
      expect(find.byIcon(FontAwesomeIcons.pen), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('tapping the edit affordance invokes onEdit, not onTap',
        (tester) async {
      var tapped = false;
      var edited = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            TopBarPill(
              id: 'reply',
              label: 'Reply',
              editIcon: FontAwesomeIcons.userPlus,
              editTooltip: 'Edit recipients',
              onTap: () => tapped = true,
              onEdit: () => edited = true,
            ),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      await tester.tap(find.byIcon(FontAwesomeIcons.userPlus));
      expect(edited, isTrue);
      expect(tapped, isFalse);
    });

    testWidgets('no edit affordance when editIcon is null', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [TopBarPill(id: 'reply', label: 'Reply', onTap: () {})],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.byIcon(FontAwesomeIcons.pen), findsNothing);
      expect(find.byIcon(FontAwesomeIcons.userPlus), findsNothing);
    });
  });
```

Add the Font Awesome import at the top of the test file:

```dart
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart`
Expected: FAIL — `TopBarPill` has no `leadingIcon`/`recipientCount`/`editIcon`/`editTooltip`/`onEdit` (compile errors).

- [ ] **Step 3: Replace the `TopBarPill` value type**

In `apps/plot/lib/widget/note_editor_top_bar.dart`, replace the entire `TopBarPill` class (the block currently spanning the doc comment + class from `/// A single pill in the [PillRowState] row.` through its constructor) with:

```dart
/// A single pill in the [PillRowState] row.
class TopBarPill {
  final String id;
  final String label;

  /// Icon drawn before the label (e.g. reply / reply-all). Null = no icon.
  final IconData? leadingIcon;

  /// Recipient count rendered in a small pill just before [editIcon].
  /// Null = no count shown.
  final int? recipientCount;

  /// Trailing edit-affordance icon (pencil to edit recipients, user-plus to
  /// add). Null = no edit affordance.
  final IconData? editIcon;

  /// Tooltip shown over the [editIcon]/[recipientCount] affordance.
  final String? editTooltip;

  /// Called when the pill body (leading icon + label) is tapped.
  final VoidCallback onTap;

  /// Called when the [recipientCount]/[editIcon] affordance is tapped (opens
  /// the recipient editor). When non-null the affordance brightens on hover.
  final VoidCallback? onEdit;

  const TopBarPill({
    required this.id,
    required this.label,
    this.leadingIcon,
    this.recipientCount,
    this.editIcon,
    this.editTooltip,
    required this.onTap,
    this.onEdit,
  });
}
```

- [ ] **Step 4: Replace the `_Pill` build body**

In the same file, in `_PillState.build`, replace the `Row(... children: [ Text(...), if (widget.pill.avatarActors != null ...) ... ])` block (the `Row` inside the `Padding` inside the `GestureDetector`) with:

```dart
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.pill.leadingIcon != null) ...[
                  Icon(
                    widget.pill.leadingIcon,
                    size: 11,
                    color: foregroundColor,
                  ),
                  const SizedBox(width: 5),
                ],
                Text(
                  widget.pill.label,
                  style: context.theme.typography.sm.copyWith(
                    color: foregroundColor,
                    fontWeight: widget.isActive
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (widget.pill.editIcon != null) ...[
                  const SizedBox(width: 6),
                  _EditAffordance(
                    count: widget.pill.recipientCount,
                    icon: widget.pill.editIcon!,
                    tooltip: widget.pill.editTooltip,
                    onTap: widget.pill.onEdit,
                  ),
                ],
              ],
            ),
```

- [ ] **Step 5: Add the `_EditAffordance` widget**

In the same file, add this class just after `_PillState` (before the "Takeover bar" section comment):

```dart
/// The recipient count pill + edit icon shown on the reply-all / reply pills.
/// Its own tap target (so it fires [onTap] instead of the pill's body tap) and
/// brightens on hover. Wrapped in an [FTooltip] when [tooltip] is set.
class _EditAffordance extends StatefulWidget {
  final int? count;
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;

  const _EditAffordance({
    required this.count,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_EditAffordance> createState() => _EditAffordanceState();
}

class _EditAffordanceState extends State<_EditAffordance> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final color = _hovering ? colors.foreground : colors.mutedForeground;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.count != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: colors.mutedForeground
                  .withValues(alpha: _hovering ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${widget.count}',
              style: context.theme.typography.xs.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Icon(widget.icon, size: 11, color: color),
      ],
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: content,
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip == null) return hoverable;
    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: hoverable,
    );
  }
}
```

- [ ] **Step 6: Remove the now-unused imports**

In the same file, delete:

```dart
import 'package:plot/store/store.dart';
import 'package:plot/widget/avatar.dart';
```

(`Actor` and `AvatarGroup` are no longer referenced. `font_awesome_flutter` and `forui` stay — used by `_TakeoverBar` and theming.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart`
Expected: PASS (all groups, including the pre-existing ones).

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/widget/note_editor_top_bar.dart apps/plot/test/widget/note_editor_top_bar_test.dart
git commit --no-verify -m "feat(note-editor): pill leading icon + count/edit affordance"
```

---

## Task 2: Rebuild `_buildPills` for the three thread types

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart` (`_buildPills`, lines ~891-1019; `_singleAvatar`, lines ~802-810)

- [ ] **Step 1: Simplify the twist-chat branch**

In `_buildPills`, replace the `if (_hasMentionableTwist(s)) { ... return pills; }` block (currently building `reply` with avatars + `private`) with:

```dart
    if (_hasMentionableTwist(s)) {
      // Twist chat: chat-like — a single Reply (to everyone) + Private note.
      pills.add(
        TopBarPill(id: 'reply', label: 'Reply', onTap: _activatePlotReply),
      );
      pills.add(
        TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate),
      );
      return pills;
    }
```

- [ ] **Step 2: Simplify the Plot-thread branch**

Replace the `if (isPlotThread) { ... }` block with:

```dart
    if (isPlotThread) {
      if (!hasSharing) {
        // Unshared Plot thread: nothing to choose between — it's just a note.
        // Returning no pills makes _buildTopBar omit the bar entirely.
        return pills;
      }
      // Shared Plot thread: chat-like — a single Reply (to everyone on the
      // thread) + Private note. No reply-to-original, no recipient editing.
      pills.add(
        TopBarPill(id: 'reply', label: 'Reply', onTap: _activatePlotReply),
      );
      pills.add(
        TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate),
      );
      return pills;
    }
```

- [ ] **Step 3: Rebuild the connector message branch**

In the `switch (cfg.sharingModel)`, replace the entire `case SharingModel.message:` block (up to its `return pills;`) with:

```dart
      case SharingModel.message:
        final replyAudience = _replyAudience(s);
        final orig = _originalAuthorIfDistinct(s);
        final bothTabs = orig != null;
        pills.add(
          TopBarPill(
            id: 'reply',
            label: bothTabs ? 'Reply all' : 'Reply',
            leadingIcon: bothTabs ? FontAwesomeIcons.replyAll : null,
            recipientCount: bothTabs ? replyAudience.total : null,
            editIcon: bothTabs ? PlotIcon.edit : PlotIcon.share,
            editTooltip: 'Edit recipients',
            onTap: _activateConnectorReply,
            onEdit: _openRecipientPicker,
          ),
        );
        if (orig != null) {
          pills.add(
            TopBarPill(
              id: 'replyOriginal',
              label: 'Reply to ${_displayName(orig)}',
              leadingIcon: FontAwesomeIcons.reply,
              onTap: () => _activateReplyToOriginal(orig),
            ),
          );
        }
        pills.add(
          TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate),
        );
        return pills;
```

(The `channel`/`thread`/`none` case below it is unchanged.)

- [ ] **Step 4: Remove the now-unused `_singleAvatar` helper**

Delete the `_singleAvatar` method (the `List<Actor> _singleAvatar(Uuid contactId) { ... }` block, ~lines 800-810, including its doc comment). `_replyAudience` and `_warmAvatarCache` stay (still used for the count).

- [ ] **Step 5: Verify it analyzes clean**

Run: `cd apps/plot && flutter analyze lib/widget/note_editor.dart lib/widget/note_editor_top_bar.dart`
Expected: No errors. (Resolve any "unused element"/"unused import" warnings by deleting the offending symbol/import.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit --no-verify -m "feat(note-editor): reply-all/reply tabs for message threads, simple Plot threads"
```

---

## Task 3: Recipient-picker placeholder → "Select recipients"

**Files:**
- Modify: `apps/plot/lib/command/share.dart` (`buildSharedSelectionCommands` ~line 183; `PickShared` factory ~line 500)
- Modify: `apps/plot/lib/widget/recipient_picker_modal.dart` (~line 158)

- [ ] **Step 1: Add a `prompt` parameter to `buildSharedSelectionCommands`**

In `apps/plot/lib/command/share.dart`, add a `prompt` parameter (default preserves today's text) to the `buildSharedSelectionCommands({...})` signature:

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
  String prompt = 'Share with contact or email',
}) async {
```

Then use it in the returned `Commands(prompt: ...)` — change `prompt: 'Share with contact or email',` to:

```dart
  return Commands(
    prompt: prompt,
    emptyMessage: 'Enter an email address to invite someone',
```

- [ ] **Step 2: Thread `prompt` through the `PickShared` factory**

In the `PickShared` factory (`factory PickShared({...})`), add the parameter and forward it. Add to the parameter list:

```dart
    String sharedSectionTitle = 'Shared',
    String threadSectionTitle = 'In this thread',
    String prompt = 'Share with contact or email',
  }) {
```

And in the `commandsBuilder: (context) => buildSharedSelectionCommands(...)` call, add:

```dart
        sharedSectionTitle: sharedSectionTitle,
        threadSectionTitle: threadSectionTitle,
        prompt: prompt,
      ),
```

- [ ] **Step 3: Pass the new prompt from the recipient picker**

In `apps/plot/lib/widget/recipient_picker_modal.dart`, in the `PickShared(...)` call inside `run()`, add `prompt: 'Select recipients',` alongside the existing args:

```dart
    await PickShared(
      selection: selection,
      title: 'Recipients',
      injectSelf: true,
      includeGroupIds: includeGroupIds,
      threadMemberIds: threadContacts.map(Uuid.fromString).toList(),
      sharedSectionTitle: 'Recipients',
      prompt: 'Select recipients',
      onUpdate: (next) async {
        selection = next;
        changed = true;
      },
    ).run(context);
```

- [ ] **Step 4: Verify it analyzes clean**

Run: `cd apps/plot && flutter analyze lib/command/share.dart lib/widget/recipient_picker_modal.dart`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/share.dart apps/plot/lib/widget/recipient_picker_modal.dart
git commit --no-verify -m "feat(share): 'Select recipients' prompt for the note recipient picker"
```

---

## Task 4: Bump the web font cache version

**Files:**
- Modify: `apps/plot/scripts/cache-bust-fonts.sh:42`

- [ ] **Step 1: Bump the version**

Change `FONT_CACHE_VERSION=15` to `FONT_CACHE_VERSION=16` (a new Font Awesome glyph, `replyAll`, is now referenced — web tree-shaking would otherwise serve a stale font and render tofu).

- [ ] **Step 2: Commit**

```bash
git add apps/plot/scripts/cache-bust-fonts.sh
git commit --no-verify -m "chore(web): bump font cache version for replyAll glyph"
```

---

## Task 5: Full verification

- [ ] **Step 1: Run the affected test file**

Run: `cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart`
Expected: PASS.

- [ ] **Step 2: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: No errors (infos are tolerated by CI's `--no-fatal-infos`, but fix any introduced by this change — especially unused imports/elements). Confirm there are no remaining references to `avatarActors`, `avatarTotalCount`, `onAvatarsTap`, or `_singleAvatar`:

Run: `grep -rn "avatarActors\|avatarTotalCount\|onAvatarsTap\|_singleAvatar" apps/plot/lib apps/plot/test`
Expected: no matches.

- [ ] **Step 3: Manual run-app verification (run-app skill)**

Verify in the running app:
- A shared **Plot thread** shows only `Reply` (no icon, no count/pencil) + `Private note`.
- A **Gmail thread with 2+ recipients and a distinct original author** shows `Reply all` (replyAll icon + count pill + pencil) + `Reply to <name>` (reply icon, no avatar) + `Private note`. Hovering the count/pencil shows the "Edit recipients" tooltip; clicking it opens the recipient picker with the "Select recipients" placeholder.
- A **Gmail thread with one other recipient** shows `Reply` (no leading icon) + a user-plus icon → opens the recipient picker; + `Private note`.

---

## Notes for the implementer

- **Roles are out of scope.** Do not add role badges/secondary-axis to the recipient picker — per-message To/Cc needs backend storage that does not exist (see the spec's "Out of scope / follow-up" section). The picker edits *who* receives the reply only.
- Use `flutter/widgets.dart` + `forui/forui.dart` only; never `flutter/material.dart`.
- UI text is sentence case ("Edit recipients", "Select recipients", "Private note").
- Desktop cursor: do **not** add `SystemMouseCursors.click` to the edit affordance — it's a button, not a link (keep the default arrow).
