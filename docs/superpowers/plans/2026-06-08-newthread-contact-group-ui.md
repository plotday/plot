# NewThreadPage contact/group add + edit UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** On the NewThreadPage step-1 picker, give contact/group rows a trailing "… More" menu (hover + Cmd+Enter) with an "Edit contact"/"Edit group" command, and add "+ Contact"/"+ Group" ghost buttons to the "People and twists" header — all opening `FormModal`s that dispatch the existing offline write commands.

**Architecture:** New UI-launching commands (`NewContact`, `EditContact`, `EditGroup`) show `FormModal`s and call the headless writes (`AddContact`/`RenameContact`/`CreateGroup`/`RenameGroup`/`AddGroupMembers`/`RemoveGroupMembers`). `PillGridItem` gains an `onMore` callback; `ComposeSectionsView` gains `onRowMore`/`onAddContact`/`onAddGroup` page callbacks mirroring `onCreateTopic`. Multiple selected contacts (an `AdHocGroupPillData`) are treated as a group: naming them runs `CreateGroup`.

**Tech Stack:** Flutter, forui (`FButton`), Drift store, the app's `Command`/`FormModal`/`CommandModal` framework.

---

## Environment / conventions (read first)

- Worktree: `/Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis`, app in `apps/plot/`. Generated files (`store.g.dart`) already built; if `flutter analyze` complains about missing generated parts, run `flutter pub get` (do NOT run build_runner — no Drift schema changes here).
- **Do NOT run `dart format`** (repo uses old short-style — formatting creates huge spurious diffs).
- **Do NOT commit gitignored generated files** (`store.g.dart`) or `app.env`.
- Baseline `flutter analyze` has 2 pre-existing issues (`new_thread.dart:1360` use_build_context_synchronously, `border_from_theme_test.dart:35` deprecated opacity) — do not add new ones.
- UI text is sentence case. Modals MUST use the project `FormModal`/`CommandModal` (never `showDialog`).

## Exact APIs (confirmed)

- `FormTextInput({required key, label, required, placeholder, maxLines, initialValue})`; `.getValue() → String`.
- `FormShareSelect({required key, label, placeholder, priority, SharedSelection? initialValue})`; `.getValue() → SharedSelection`. `SharedSelection({List<Uuid> contacts, List<Uuid> groups, List<String> inviteEmails})` (from `command/share.dart`).
- `FormButton({required key, bool isPrimary, required Command Function(Map<String,dynamic> values) buildCommand})`. `values['<key>']` = each item's `getValue()`.
- `FormData({required title, required List<FormGroup> groups, onRefresh, dismissable})`; `StaticFormGroup({title, subtitle, required List<FormItem> items})`; `await form.list()` → `List<StaticFormGroup>`.
- `FormModal(form, groups: groups, rootContext: context, constraints: ...).run(context) → Future<CommandReturn>`. Success ⇒ `result is CommandDone`.
- `CommandModal(Commands, rootContext: context).run(context)`; `Commands(groups: [StaticCommandGroup(commands: [cmd])])` (from `command/base.dart`).
- `ActorRow.id → ActorId` (already an `ActorId`); `.name/.email → String?`; `Actor.nameOrEmail → String`. `ActorId.toUuid() → Uuid`, `ActorId.fromUuid(Uuid)`. `GroupRow.id → Uuid`, `.name → String`.
- Write-command signatures: `RenameContact({ActorId contactId, String name})`; `AddContact({required String name, required String email})` (to be relaxed in Task 1); `CreateGroup({required String name, String privacy='open', List<Uuid> memberContactIds})`; `RenameGroup({Uuid groupId, String name})`; `AddGroupMembers({String groupId, List<String> contactIds})`; `RemoveGroupMembers({String groupId, List<String> contactIds})`.

## File structure

- `apps/plot/lib/command/contact.dart` — relax `AddContact.name`; add `NewContact`, `EditContact`.
- `apps/plot/lib/command/group.dart` — add `EditGroup`, a private `_SaveGroupEdit` composite, and a pure `groupMembershipDiff` helper (exported for test).
- `apps/plot/lib/widget/compose/pill_grid.dart` — `PillGridItem.onMore`; trailing "…" in row; `moreHighlighted()`.
- `apps/plot/lib/widget/compose/compose_sections_view.dart` — `onRowMore`/`onAddContact`/`onAddGroup` callbacks; `_peopleHeader()` ghost buttons; set `onMore`; Cmd+Enter shortcut.
- `apps/plot/lib/page/new_thread.dart` — `_rowMore`, `_addContact`, `_addGroup` callbacks; wire into `ComposeSectionsView`.
- `apps/plot/test/command/group_membership_diff_test.dart` — unit test the pure diff.

---

## Task 1: Contact commands (`NewContact`, `EditContact`) + relax `AddContact`

**Files:** Modify `apps/plot/lib/command/contact.dart`

- [ ] **Step 1: Relax `AddContact` to accept an optional name**

In `apps/plot/lib/command/contact.dart`, change `AddContact` so `name` is optional/nullable (email-only contacts). Change the field to `final String? name;` and the constructor to `AddContact({this.name, required this.email})`, and in `run()` change the companion's `name:` to `name: Value(name)` (it already wraps in `Value`; `Value(null)` is fine — `save_user_contact`'s `p_name` accepts null). Verify the rest of `run()` is unchanged.

- [ ] **Step 2: Add `EditContact` (rename, name-only; email read-only)**

Append to `apps/plot/lib/command/contact.dart`:

```dart
/// Edit a contact from the new-thread picker: rename only (per-user override).
/// The email is shown read-only as the form-group subtitle for context.
class EditContact extends Command {
  EditContact({
    required this.contactId,
    required this.currentName,
    this.email,
  }) : super(
          title: 'Edit contact',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final ActorId contactId;
  final String currentName;
  final String? email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        initialValue: currentName,
        placeholder: 'Name',
      ),
      FormButton(
        key: 'save',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          return RenameContact(contactId: contactId, name: name);
        },
      ),
    ];
    final form = FormData(
      title: 'Edit contact',
      dismissable: true,
      groups: [
        StaticFormGroup(subtitle: email, items: items),
      ],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 360, maxWidth: 460),
    ).run(context);
  }
}
```

- [ ] **Step 3: Add `NewContact` (add by name + email)**

Append:

```dart
/// Add a new contact (name optional, email required) from the picker header.
class NewContact extends Command {
  NewContact()
    : super(
        title: 'Add contact',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        placeholder: 'Optional',
      ),
      FormTextInput(
        key: 'email',
        label: 'Email',
        required: true,
        placeholder: 'name@example.com',
      ),
      FormButton(
        key: 'add',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          final email = (values['email'] as String?)?.trim() ?? '';
          return AddContact(name: name.isEmpty ? null : name, email: email);
        },
      ),
    ];
    final form = FormData(
      title: 'Add contact',
      dismissable: true,
      groups: [StaticFormGroup(items: items)],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 420, maxWidth: 460),
    ).run(context);
  }
}
```

- [ ] **Step 4: Imports + barrel**

Add any missing imports to `contact.dart`: `package:flutter/widgets.dart` (BoxConstraints) — likely already via `widget/widget.dart`; `package:plot/widget/form.dart` and `package:plot/widget/form_modal.dart` for `FormData`/`FormItem`/`FormTextInput`/`FormButton`/`StaticFormGroup`/`FormModal`. Match how `command/topic.dart` imports them (read its imports). Confirm `command/command.dart` already `export 'contact.dart';` (it does).

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/command/contact.dart 2>&1 | tail -10
```
Expected: No issues. Then:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis
git add apps/plot/lib/command/contact.dart
git commit -m "feat(app): NewContact/EditContact commands; AddContact optional name"
```

---

## Task 2: Group commands (`EditGroup` + composite + pure diff)

**Files:** Modify `apps/plot/lib/command/group.dart`; Create `apps/plot/test/command/group_membership_diff_test.dart`

- [ ] **Step 1: Add the pure membership-diff helper (test-first)**

Create the failing test `apps/plot/test/command/group_membership_diff_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/group.dart';
import 'package:plot/util/uuid.dart';

void main() {
  Uuid u(int n) => Uuid.fromString('00000000-0000-0000-0000-${n.toString().padLeft(12, '0')}');

  test('groupMembershipDiff computes added and removed', () {
    final prev = [u(1), u(2), u(3)];
    final next = [u(2), u(3), u(4)];
    final diff = groupMembershipDiff(prev, next);
    expect(diff.added.map((x) => x.toString()), [u(4).toString()]);
    expect(diff.removed.map((x) => x.toString()), [u(1).toString()]);
  });

  test('groupMembershipDiff is empty when unchanged', () {
    final same = [u(1), u(2)];
    final diff = groupMembershipDiff(same, [u(2), u(1)]);
    expect(diff.added, isEmpty);
    expect(diff.removed, isEmpty);
  });

  test('groupMembershipDiff handles empty next (remove all)', () {
    final diff = groupMembershipDiff([u(1), u(2)], const []);
    expect(diff.added, isEmpty);
    expect(diff.removed.length, 2);
  });
}
```

Run to confirm it fails (`groupMembershipDiff` undefined):
```bash
cd apps/plot && flutter test test/command/group_membership_diff_test.dart 2>&1 | tail -10
```

- [ ] **Step 2: Implement `groupMembershipDiff` + `GroupMembershipDiff`**

Add to `apps/plot/lib/command/group.dart` (top-level):

```dart
/// The membership delta between a group's previous and next member sets.
class GroupMembershipDiff {
  const GroupMembershipDiff({required this.added, required this.removed});
  final List<Uuid> added;
  final List<Uuid> removed;
}

/// Computes which contacts were added/removed between [prev] and [next].
/// Order-independent; dedupe relies on Uuid value equality.
GroupMembershipDiff groupMembershipDiff(List<Uuid> prev, List<Uuid> next) {
  final prevSet = prev.toSet();
  final nextSet = next.toSet();
  return GroupMembershipDiff(
    added: next.where((u) => !prevSet.contains(u)).toList(),
    removed: prev.where((u) => !nextSet.contains(u)).toList(),
  );
}
```

Run the test → expect 3 passing.

- [ ] **Step 3: Add the `_SaveGroupEdit` composite command**

Add to `apps/plot/lib/command/group.dart`:

```dart
/// Performs the save side of [EditGroup]: create a new group, or rename +
/// apply a membership diff on an existing one. Reuses the headless write
/// commands so offline/sync behavior is identical.
class _SaveGroupEdit extends Command {
  _SaveGroupEdit({
    required this.groupId,
    required this.name,
    required this.originalName,
    required this.members,
    required this.originalMembers,
  }) : super(
          title: 'Save group',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final Uuid? groupId;
  final String name;
  final String originalName;
  final List<Uuid> members;
  final List<Uuid> originalMembers;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (groupId == null) {
      return CreateGroup(name: name, memberContactIds: members).run(context);
    }
    final gid = groupId!;
    var changed = false;
    if (name != originalName && name.isNotEmpty) {
      final r = await RenameGroup(groupId: gid, name: name).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    if (!context.mounted) return const CommandSkipped();
    final diff = groupMembershipDiff(originalMembers, members);
    if (diff.added.isNotEmpty) {
      final r = await AddGroupMembers(
        groupId: gid.toString(),
        contactIds: diff.added.map((u) => u.toString()).toList(),
      ).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    if (!context.mounted) return const CommandSkipped();
    if (diff.removed.isNotEmpty) {
      final r = await RemoveGroupMembers(
        groupId: gid.toString(),
        contactIds: diff.removed.map((u) => u.toString()).toList(),
      ).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    return changed
        ? const CommandDone(message: 'Group updated')
        : const CommandSkipped();
  }
}
```

- [ ] **Step 4: Add `EditGroup` (the form-launching command)**

Add to `apps/plot/lib/command/group.dart`:

```dart
/// Edit a group, create a new group, or name an ad-hoc set of contacts as a
/// group. groupId == null => create (used by the ad-hoc row menu and the
/// "+ Group" header button); groupId != null => rename + membership diff.
class EditGroup extends Command {
  EditGroup({
    this.groupId,
    this.initialName = '',
    this.initialMemberContactIds = const [],
  }) : super(
          title: groupId == null ? 'Create group' : 'Edit group',
          eventObject: EventObject.activity,
          eventAction:
              groupId == null ? EventAction.added : EventAction.updated,
        );

  final Uuid? groupId;
  final String initialName;
  final List<Uuid> initialMemberContactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        required: true,
        initialValue: initialName,
        placeholder: 'e.g. Marketing',
      ),
      FormShareSelect(
        key: 'members',
        label: 'Members',
        placeholder: 'Add people and groups',
        initialValue: SharedSelection(contacts: initialMemberContactIds),
      ),
      FormButton(
        key: 'save',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          final sel = values['members'] as SharedSelection?;
          final members = sel?.contacts ?? const <Uuid>[];
          return _SaveGroupEdit(
            groupId: groupId,
            name: name,
            originalName: initialName,
            members: members,
            originalMembers: initialMemberContactIds,
          );
        },
      ),
    ];
    final form = FormData(
      title: groupId == null ? 'New group' : 'Edit group',
      dismissable: true,
      groups: [StaticFormGroup(items: items)],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 460),
    ).run(context);
  }
}
```

- [ ] **Step 5: Imports**

Ensure `group.dart` imports `package:plot/widget/form.dart`, `package:plot/widget/form_modal.dart`, and `package:plot/command/share.dart` (for `SharedSelection`) — match `command/topic.dart`. Note `SharedSelection` only exposes `contacts` we use (groups/inviteEmails ignored for group membership v1). Confirm `command/command.dart` exports `group.dart` (it does).

- [ ] **Step 6: Analyze, test, commit**

```bash
cd apps/plot && flutter analyze lib/command/group.dart test/command/group_membership_diff_test.dart 2>&1 | tail -10
flutter test test/command/group_membership_diff_test.dart 2>&1 | tail -8
```
Expected: no issues; 3 tests pass. Then:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis
git add apps/plot/lib/command/group.dart apps/plot/test/command/group_membership_diff_test.dart
git commit -m "feat(app): EditGroup command (create/rename/membership) + diff helper + test"
```

---

## Task 3: PillGrid trailing "…" affordance + Cmd+Enter hook

**Files:** Modify `apps/plot/lib/widget/compose/pill_grid.dart`

- [ ] **Step 1: Add `onMore` to `PillGridItem`**

Change the `PillGridItem` constructor/field to add an optional `onMore`:

```dart
class PillGridItem {
  PillGridItem({
    required this.data,
    required this.onActivate,
    this.onMore,
  });

  final ComposePillData data;
  final VoidCallback onActivate;

  /// Optional "… More" action (Edit). When non-null, the row shows a trailing
  /// "…" button while highlighted and Cmd+Enter on the highlighted row fires it.
  final VoidCallback? onMore;
}
```

- [ ] **Step 2: Render the trailing "…" on the highlighted row**

In `PillGridState.build()`, change the per-item `_rowChrome(child: ComposePill(data: item.data))` so the child is a `Row` with the pill expanded and a trailing "…" button shown when `item.onMore != null && index == _highlighted`. Replace the `child:` of `_rowChrome` with:

```dart
                child: _rowChrome(
                  context,
                  highlighted: index == _highlighted,
                  child: Row(
                    children: [
                      Expanded(child: ComposePill(data: item.data)),
                      if (item.onMore != null && index == _highlighted)
                        _moreButton(context, item.onMore!),
                    ],
                  ),
                ),
```

Add a `_moreButton` helper to `PillGridState` (a ghost icon button whose own tap fires `onMore` and does NOT bubble to the row's `onActivate`):

```dart
  Widget _moreButton(BuildContext context, VoidCallback onMore) {
    return FButton(
      onPress: onMore,
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        iconSize: context.theme.iconSizes.sm,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      mainAxisSize: MainAxisSize.min,
      child: const Icon(PlotIcon.more),
    );
  }
```

Add imports to `pill_grid.dart` if missing: `package:plot/style/button.dart' show ghostSizedStyleDelta;` and the icon (`PlotIcon.more` from `package:plot/widget/icon.dart` — verify the exact "…" icon constant exists; if `PlotIcon.more` doesn't exist, grep `lib/widget/icon.dart` for the ellipsis/more icon and use that). `FButton`/`FButtonVariant` come from forui (already used in `compose_sections_view.dart`).

> The inner `FButton` wins the tap on its own area, so tapping "…" fires `onMore` not the row's `onActivate`. Verify this at analyze/run time; if the outer `GestureDetector(HitTestBehavior.opaque)` still steals the tap, wrap `_moreButton` in a `GestureDetector(onTap: () {}, behavior: HitTestBehavior.opaque, child: ...)` or use a `Listener` to absorb the pointer.

- [ ] **Step 3: Add `moreHighlighted()` to `PillGridState`**

Next to `activateHighlighted()`:

```dart
  /// Fires the "… More" action of the highlighted row, if it has one.
  /// Returns true if an action fired (so the host can swallow the key event).
  bool moreHighlighted() {
    if (_highlighted < 0 || _highlighted >= _flat.length) return false;
    final onMore = _flat[_highlighted].onMore;
    if (onMore == null) return false;
    onMore();
    return true;
  }
```

- [ ] **Step 4: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/widget/compose/pill_grid.dart 2>&1 | tail -10
```
Expected: no issues. Commit:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis
git add apps/plot/lib/widget/compose/pill_grid.dart
git commit -m "feat(app): trailing … More affordance + moreHighlighted on PillGrid"
```

---

## Task 4: ComposeSectionsView wiring (onMore, header buttons, Cmd+Enter)

**Files:** Modify `apps/plot/lib/widget/compose/compose_sections_view.dart`

- [ ] **Step 1: Add the three callbacks to the widget**

Add to `ComposeSectionsView`'s constructor + fields (alongside `onCreateTopic`):

```dart
    this.onRowMore,
    this.onAddContact,
    this.onAddGroup,
```
```dart
  /// Opens the "… More" (Edit) menu for an editable people row. Null hides
  /// the affordance.
  final Future<void> Function(ComposePillData data)? onRowMore;

  /// Opens the add-contact form (People & twists header "+ Contact"). Returns
  /// true when a contact was added (so sections reload). Null hides the button.
  final Future<bool> Function()? onAddContact;

  /// Opens the add-group form (People & twists header "+ Group"). Returns true
  /// when a group was created. Null hides the button.
  final Future<bool> Function()? onAddGroup;
```

- [ ] **Step 2: Set `onMore` on editable people items**

In `_buildSections()`, change the `personItems` construction to set `onMore` for contact/group/ad-hoc pills:

```dart
    final personItems = [
      for (final e in s.people)
        PillGridItem(
          data: e.display,
          onActivate: () => widget.onPickRecipient(e),
          onMore: _rowMoreFor(e.display),
        ),
    ];
```

Add a helper:

```dart
  /// Builds the "… More" callback for editable people rows (contact, group,
  /// ad-hoc multi-contact); null for everything else.
  VoidCallback? _rowMoreFor(ComposePillData data) {
    final onRowMore = widget.onRowMore;
    if (onRowMore == null) return null;
    final editable = data is ContactPillData ||
        data is GroupPillData ||
        data is AdHocGroupPillData;
    if (!editable) return null;
    return () async {
      await onRowMore(data);
      if (!_isDisposed) _reload();
    };
  }
```

(`ContactPillData`/`GroupPillData`/`AdHocGroupPillData` are already importable via `compose_pill.dart`. `_isDisposed`/`_reload()` already exist — used by `_onCreateTopicPressed`.)

- [ ] **Step 3: Header ghost buttons in `_peopleHeader()`**

Replace `_peopleHeader()` with a header row mirroring `_channelsHeader()`:

```dart
  /// The "People and twists" section header, with right-aligned "+ Contact"
  /// and "+ Group" ghost buttons (each shown only when its callback is given).
  Widget _peopleHeader() {
    return Builder(
      builder: (context) {
        return Row(
          children: [
            Text('People and twists', style: _headingStyle(context)),
            const Spacer(),
            if (widget.onAddContact != null)
              _headerGhostButton(
                context,
                label: 'Contact',
                onPress: () => _onAddPressed(widget.onAddContact!),
              ),
            if (widget.onAddGroup != null) ...[
              SizedBox(width: context.theme.spacing.xs),
              _headerGhostButton(
                context,
                label: 'Group',
                onPress: () => _onAddPressed(widget.onAddGroup!),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _headerGhostButton(
    BuildContext context, {
    required String label,
    required VoidCallback onPress,
  }) {
    return FButton(
      onPress: onPress,
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
        iconSize: context.theme.iconSizes.xs,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [const Icon(PlotIcon.add), Text(label)],
      ),
    );
  }

  Future<void> _onAddPressed(Future<bool> Function() add) async {
    final created = await add();
    if (created && !_isDisposed) _reload();
  }
```

(Reuses the same `ghostSizedStyleDelta` import and `_isDisposed`/`_reload()` already present.)

- [ ] **Step 4: Cmd+Enter → moreHighlighted via CallbackShortcuts**

Wrap the `build()`'s top-level `Column` (the one containing `ComposeSearchField` + `PillGrid`) in a `CallbackShortcuts` so Cmd/Ctrl+Enter fires the highlighted row's More action. Add imports `package:flutter/services.dart` (for `LogicalKeyboardKey`, `SingleActivator`) and `package:flutter/widgets.dart` (for `CallbackShortcuts`) if not present. Change the `return Column(...)` to:

```dart
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          _gridKey.currentState?.moreHighlighted();
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          _gridKey.currentState?.moreHighlighted();
        },
      },
      child: Column(
        // ... existing children unchanged ...
      ),
    );
```

(`CallbackShortcuts` receives the event because the focused `ComposeSearchField` is inside its subtree; with the modifier held, the text field does not treat Enter as submit. The plain-Enter `onSubmit → activateHighlighted()` path is unchanged.)

- [ ] **Step 5: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/widget/compose/compose_sections_view.dart 2>&1 | tail -12
```
Expected: no new issues. Commit:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis
git add apps/plot/lib/widget/compose/compose_sections_view.dart
git commit -m "feat(app): row More menu + People-header add buttons + Cmd+Enter wiring"
```

---

## Task 5: NewThreadPage callbacks

**Files:** Modify `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add the three page callbacks**

Add methods to `NewThreadPageState`, near `_createTopic`:

```dart
  /// Opens the "… More" (Edit) menu for an editable people row.
  Future<void> _rowMore(ComposePillData data) async {
    final Command command;
    switch (data) {
      case ContactPillData(:final actor):
        command = EditContact(
          contactId: actor.id,
          currentName: actor.name ?? '',
          email: actor.email,
        );
      case GroupPillData(:final group, :final members):
        command = EditGroup(
          groupId: group.id,
          initialName: group.name,
          initialMemberContactIds:
              members.map((a) => a.id.toUuid()).toList(),
        );
      case AdHocGroupPillData(:final actors):
        command = EditGroup(
          groupId: null,
          initialName: '',
          initialMemberContactIds:
              actors.map((a) => a.id.toUuid()).toList(),
        );
      default:
        return; // not editable
    }
    final commands = Commands(
      groups: [
        StaticCommandGroup(commands: [command]),
      ],
    );
    await CommandModal(commands, rootContext: context).run(context);
  }

  /// "+ Contact" header button → add a contact. Returns true if added.
  Future<bool> _addContact() async {
    final result = await NewContact().run(context);
    return result is CommandDone;
  }

  /// "+ Group" header button → create a group. Returns true if created.
  Future<bool> _addGroup() async {
    final result = await EditGroup().run(context);
    return result is CommandDone;
  }
```

- [ ] **Step 2: Wire into `ComposeSectionsView`**

In the `ComposeSectionsView(...)` construction (where `onCreateTopic: _createTopic` is set), add:

```dart
      onRowMore: _rowMore,
      onAddContact: _addContact,
      onAddGroup: _addGroup,
```

- [ ] **Step 3: Imports**

Ensure `new_thread.dart` imports the pill data types (`ContactPillData`/`GroupPillData`/`AdHocGroupPillData`/`ComposePillData` from `compose_pill.dart`), `Commands`/`StaticCommandGroup` (from `command/command.dart` / `command/base.dart`), `CommandModal` (`widget/command_modal.dart`), and `EditContact`/`NewContact`/`EditGroup` (via `command/command.dart`). Most are likely already imported; add what `flutter analyze` flags.

- [ ] **Step 4: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/page/new_thread.dart 2>&1 | tail -12
```
Expected: no NEW issues (the pre-existing `new_thread.dart:1360` use_build_context_synchronously info may still show — leave it; do not introduce new async-gap warnings in your added code: guard `context.mounted` where you `await` before using `context`, matching the existing code). Commit:
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/user-contacts-groups-apis
git add apps/plot/lib/page/new_thread.dart
git commit -m "feat(app): wire row More menu + add-contact/group buttons on NewThreadPage"
```

---

## Task 6: Whole-feature verification

- [ ] **Step 1: Full analyze**

```bash
cd apps/plot && flutter analyze 2>&1 | tail -8
```
Expected: only the 2 pre-existing baseline issues; 0 new.

- [ ] **Step 2: Run the unit test**

```bash
cd apps/plot && flutter test test/command/group_membership_diff_test.dart 2>&1 | tail -8
```
Expected: 3 passing.

- [ ] **Step 3: `/finalize`**

Run the `/finalize` checklist. Notes: no backend/schema change; no removed/renamed APIs (`AddContact.name` became optional — additive, no caller breaks since it had none); error capture — the new commands surface expected errors via `CommandMessage` (no `captureException` needed); docs — this is now a user-facing capability, so add a brief `docs/updates.md` bullet ("Add and edit contacts and groups from the new-thread screen") and consider a `docs/features.md` line; no `public/` changes.

- [ ] **Step 4: Final commit (if `/finalize` changed anything)**

```bash
git add -A && git commit -m "chore: finalize new-thread contact/group UI"
```

---

## Self-review notes (addressed)

- **Spec coverage:** row "…" menu (Task 3+4+5), Cmd+Enter (Task 3 `moreHighlighted` + Task 4 CallbackShortcuts), Edit contact name-only/email-read-only (Task 1 `EditContact`), Edit group create/rename/diff + ad-hoc (Task 2 `EditGroup`/`_SaveGroupEdit`), header "+ Contact"/"+ Group" (Task 4 `_peopleHeader` + Task 5 callbacks), `AddContact` empty name (Task 1), pure-diff test (Task 2).
- **Type consistency:** `EditContact.contactId: ActorId` ← `actor.id` (already ActorId); `EditGroup.initialMemberContactIds: List<Uuid>` ← `members.map((a)=>a.id.toUuid())`; `RenameGroup.groupId: Uuid`; `AddGroupMembers/RemoveGroupMembers.groupId: String` ← `gid.toString()`, `contactIds: List<String>` ← `u.toString()`. `FormShareSelect.getValue() → SharedSelection`, `.contacts: List<Uuid>`.
- **Known verify-points** (codegen/icon specifics the analyzer pins down, not undecided design): the exact "…" icon constant (`PlotIcon.more` or equivalent); that the inner "…" `FButton` tap doesn't bubble to the row `onActivate`; that nested `CommandModal → FormModal` stacks correctly (the app's `ModalProvider` should handle it); `FormTextInput` has no read-only flag, so `EditContact` shows email as the form-group subtitle.
