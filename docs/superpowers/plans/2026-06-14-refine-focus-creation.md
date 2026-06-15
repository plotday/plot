# Refine the Focus Creation Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Add a focus" start by choosing (or creating) a role, then a focus template,
using one shared role-selection modal everywhere a role is picked.

**Architecture:** Flutter-client-only change to the focus-creation command flow in
`apps/plot/lib/command/priority.dart`, the curated template list in
`command/focus_suggestions.dart`, and the generic `FormSelect` picker in `widget/form.dart`.
The new step-1 modal and the create/edit forms' Role field both use a `SelectModal<Role>`
listing existing roles plus a labeled "Add role" row (rendered via `SelectModal`'s existing
info-only group mechanism). No schema, migration, sync, or Twister changes.

**Tech Stack:** Dart / Flutter, forui widgets, Drift store, Bloc commands.

---

## Background for the implementer

- A **focus** is a `Priority` (`store/priority.dart`). A **role** (`store/role.dart`,
  `RoleId = Uuid`) groups focuses. `Role.all()` returns the user's roles; `Role.displayColor`
  is its colour; there is always ≥1 role (seeded "Personal").
- "Add a focus" is the `AddFocus` command (`command/priority.dart`). It is invoked from the
  sidebar tile (`widget/priorities_list.dart:159`, `AddFocus(defaultRoleId: expandedRoleId)`)
  and the command palette (`command/global.dart:51`, `AddFocus()`). `defaultRoleId` is the
  currently-selected focus's role — a soft default, not an explicit target.
- Focus templates are `kFocusSuggestions` (`command/focus_suggestions.dart`), surfaced today
  by a `ShowCommands` picker inside `AddFocus`. Picking one opens `NewFocus` (a two-step form)
  prefilled. `NewFocus`/`AddFocus`/`_buildFocusDetailsForm` already thread `defaultRoleId`.
- The create form (`_buildFocusDetailsForm`) and edit form (`EditPriorityCommand`) already
  have a Role field built by `_roleSelect` — a `FormSelect<Role>` with
  `onAdd: createRoleInline` (currently a subtle "+" button). `createRoleInline`
  (`command/role.dart`) opens the `AddRole` name+colour form and returns the new `Role`.
- `SelectModal<T>` (`widget/select_modal.dart`) supports `title`, `selectedValue`,
  `itemBuilder`, `onAdd` ("+" button), and **info-only groups**: a `SelectGroup<T>` with
  empty `items`, an `infoBuilder` (renders a row), and `onActivate` (fires on Enter/tap). It
  is keyboard-navigable. `SelectModal.open<T>(...)` returns a Drift `Value<T>`
  (`.present`/`.value`). `Modal.pop<T>(context, Value<T>)` closes a modal with a result.
- `widget/widget.dart` is a barrel exporting `modal.dart`, `select_modal.dart`,
  `list_tile.dart`, `icon.dart`. Both `form.dart` and `command/priority.dart` import it, so
  `Modal`, `SelectModal`, `SelectGroup`, `PlotIcon`, and the new `addItemRow` helper are all
  reachable without new imports. `command/priority.dart` imports `command.dart` (which exports
  `role.dart`, giving `createRoleInline`) and `color_dot.dart` (`ColorDot`).
- Lint: `cd apps/plot && flutter analyze` must be clean. Async `onActivate` closures are an
  established pattern (`widget/form_modal.dart:590`); no `discarded_futures` lint is enabled.
- **UI text is sentence case** (project rule). Modals must use the project `Modal`/its tuned
  variants — we only use `SelectModal`/`ShowCommands`/`ShowForm`, which already comply.

---

## File map

- `apps/plot/lib/command/focus_suggestions.dart` — remove 3 `FocusPrefill` entries (Task 1).
- `apps/plot/test/command/focus_suggestions_test.dart` — guard test for the removals (Task 1).
- `apps/plot/lib/widget/select_modal.dart` — add the shared `addItemRow` helper (Task 2).
- `apps/plot/lib/widget/form.dart` — add `FormSelect.addLabel`, render the labeled add-row
  (Task 3).
- `apps/plot/lib/command/priority.dart` — `_roleSelect` passes `addLabel: 'Add role'` (Task 3);
  Role field first in create + edit forms (Task 4); restructure `AddFocus` to a role-chooser →
  templates flow, rename `_CreateCustomFocus` → `_CreateOtherFocus` ("Other"), drop the
  "Suggestions" heading, move "Other" last (Task 5).

---

## Task 1: Drop role/FYI-redundant focus templates

**Files:**

- Modify: `apps/plot/lib/command/focus_suggestions.dart` (entries at lines ~98–125)
- Test: `apps/plot/test/command/focus_suggestions_test.dart`

- [ ] **Step 1: Write the failing test**

Add this test to `apps/plot/test/command/focus_suggestions_test.dart` (inside `main()`):

```dart
  test('role/FYI-redundant templates are no longer offered', () {
    final keys = kFocusSuggestions.map((s) => s.suggestionKey).toSet();
    expect(keys, isNot(contains('volunteering')));
    expect(keys, isNot(contains('personal_admin')));
    expect(keys, isNot(contains('promotions')));
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/command/focus_suggestions_test.dart`
Expected: FAIL — the new test fails because all three keys are still present.

- [ ] **Step 3: Remove the three entries**

In `apps/plot/lib/command/focus_suggestions.dart`, delete these three `FocusPrefill` blocks
from `kFocusSuggestions` (leave the other eight untouched):

```dart
  FocusPrefill(
    suggestionKey: 'volunteering',
    title: 'Volunteering',
    description: 'Everything related to a volunteer role',
    iconKey: 'handHoldingHeart',
    color: ThemeColor(4),
  ),
```

```dart
  FocusPrefill(
    suggestionKey: 'personal_admin',
    title: 'Personal admin',
    description: 'Errands, appointments, and personal to-dos',
    iconKey: 'house',
    color: ThemeColor(3),
  ),
```

```dart
  FocusPrefill(
    suggestionKey: 'promotions',
    title: 'Promotions',
    description: 'Offers and updates from brands you follow',
    iconKey: 'billboard',
    color: ThemeColor(6),
  ),
```

The surviving order is: `project`, `customers`, `operations`, `management`, `recruiting`,
`admin`, `reading`, `social`. (Per the list's maintenance note, stored dismissals of removed
keys become harmless orphans — no migration needed.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/command/focus_suggestions_test.dart`
Expected: PASS — all five tests (the four existing + the new guard) pass.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/focus_suggestions.dart \
        apps/plot/test/command/focus_suggestions_test.dart
git commit -m "feat(focus): drop Volunteering/Personal admin/Promotions templates"
```

---

## Task 2: Add the shared `addItemRow` helper

A single row widget so the "Add role" affordance looks identical in the new step-1 modal and
inside `FormSelect`'s Role-field picker.

**Files:**

- Modify: `apps/plot/lib/widget/select_modal.dart` (add a top-level function after the
  `SelectGroup` class, i.e. after line ~49)

- [ ] **Step 1: Add the helper**

In `apps/plot/lib/widget/select_modal.dart`, add this top-level function immediately after the
`SelectGroup` class definition (after its closing `}` near line 49):

```dart
/// A keyboard-navigable "add a new item" row for a [SelectModal] info-only
/// group. Renders a "+" icon and [label] in the muted action style. Pair it
/// with a [SelectGroup] whose `infoBuilder` returns this and whose `onActivate`
/// creates the item, then pops the modal (or advances the flow). Shared so the
/// inline-create affordance looks identical wherever a picker offers it.
Widget addItemRow(BuildContext context, {required String label}) {
  return Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.theme.spacing.lg,
      vertical: context.theme.spacing.md,
    ),
    child: Row(
      children: [
        Icon(
          PlotIcon.add,
          size: context.theme.iconSizes.sm,
          color: context.theme.colors.mutedForeground,
        ),
        SizedBox(width: context.theme.spacing.md),
        Text(
          label,
          style: TextStyle(color: context.theme.colors.mutedForeground),
        ),
      ],
    ),
  );
}
```

(`PlotIcon` comes from the already-imported `icon.dart`; `context.theme.spacing`,
`iconSizes`, and `colors.mutedForeground` are already used throughout this file.)

- [ ] **Step 2: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/widget/select_modal.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/select_modal.dart
git commit -m "feat(select): shared addItemRow for inline-create pickers"
```

---

## Task 3: `FormSelect.addLabel` — render a labeled add-row, and use it for roles

When `addLabel` is set (with `onAdd`), the picker shows a labeled row at the bottom of the
list instead of the subtle "+" button. Then the create/edit Role fields opt in with
`addLabel: 'Add role'`.

**Files:**

- Modify: `apps/plot/lib/widget/form.dart` (`FormSelect` constructor ~260–285, fields ~321,
  `activate` ~388–477)
- Modify: `apps/plot/lib/command/priority.dart` (`_roleSelect` ~563–602)

- [ ] **Step 1: Add the `addLabel` field + constructor param**

In `apps/plot/lib/widget/form.dart`, in the `FormSelect` constructor parameter list (the
block ending around line 279 `bool hasInitialValue = false,`), add a parameter:

```dart
    this.addLabel,
```

Then, near the `onAdd` field declaration (around line 319–321), add the field with docs:

```dart
  /// When set together with [onAdd], the selection modal renders a labeled
  /// "[addLabel]" row at the bottom of the list (keyboard-navigable) instead of
  /// the "+" search-field button. Activating it runs [onAdd] and, on a non-null
  /// result, selects it. Leave null to keep the legacy "+" button.
  final String? addLabel;
```

- [ ] **Step 2: Render the add-row in `activate`**

In `FormSelect.activate` (around line 395), replace the `SelectModal.open<T>` call's `items:`
callback and `onAdd:` argument. Change this:

```dart
    final result = await SelectModal.open<T>(
      context,
      items: (search) async {
        final itemsList = await items(search);
        return [SelectGroup(title: null, items: itemsList)];
      },
```

…to this:

```dart
    final useAddRow = addLabel != null && onAdd != null;
    final result = await SelectModal.open<T>(
      context,
      items: (search) async {
        final itemsList = await items(search);
        return [
          SelectGroup<T>(title: null, items: itemsList),
          if (useAddRow)
            SelectGroup<T>(
              items: <T>[],
              infoBuilder: (ctx) => addItemRow(ctx, label: addLabel!),
              onActivate: (ctx) async {
                final created = await onAdd!(ctx);
                if (created != null && ctx.mounted) {
                  Modal.pop<T>(ctx, Value(created));
                }
              },
            ),
        ];
      },
```

…and change the `onAdd:` argument **inside this same `SelectModal.open(...)` call** (around
line 475 — not the unrelated `onAdd: onAdd,` at ~1133, which belongs to a different class)
from:

```dart
      onAdd: onAdd,
```

to:

```dart
      onAdd: useAddRow ? null : onAdd,
```

(`Modal`, `SelectGroup`, and `addItemRow` are exported by the already-imported `widget.dart`
barrel; `Value` is the already-imported Drift `Value`.)

- [ ] **Step 3: Opt the Role field into the labeled row**

In `apps/plot/lib/command/priority.dart`, in `_roleSelect` (around line 571), add `addLabel`
to the `FormSelect<Role>(...)` so it reads:

```dart
  field = FormSelect<Role>(
    key: 'role',
    label: 'Role',
    required: true,
    initialValue: initialRole,
    hasInitialValue: initialRole != null,
    addLabel: 'Add role',
    items: (search) async => (await Role.all())
```

(leave the rest of `_roleSelect` — `items`, `onAdd: createRoleInline`, `onChanged` — unchanged.)

- [ ] **Step 4: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/widget/form.dart lib/command/priority.dart`
Expected: "No issues found!"

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/form.dart apps/plot/lib/command/priority.dart
git commit -m "feat(form): labeled add-row for FormSelect; Role field uses 'Add role'"
```

---

## Task 4: Put the Role field first on the create and edit forms

**Files:**

- Modify: `apps/plot/lib/command/priority.dart` — `_buildFocusDetailsForm` items (~806–865) and
  `EditPriorityCommand` items (~1343–1383)

- [ ] **Step 1: Reorder the create form**

In `_buildFocusDetailsForm`, the `StaticFormGroup` `items:` list currently begins with `title`,
then `description`, then `roleField`. Move `roleField` to the **front**. Change the start of the
items list from:

```dart
      StaticFormGroup(
        items: [
          FormTextInput(
            key: 'title',
            label: 'Focus name',
            required: true,
            initialValue: prefill?.title,
          ),
          // Description last (just above the buttons): it feeds thread matching,
          // so it reads as the lead-in to "Find matching threads".
          FormTextInput(
            key: 'description',
            label: 'Description',
            required: true,
            maxLines: 3,
            placeholder: 'What belongs in this focus?',
            initialValue: prefill?.description,
          ),
          roleField,
          _focusIconSelect(initial: prefill?.iconKey ?? 'bullseyePointer'),
          colorField,
```

…to this (role first; everything else keeps its order):

```dart
      StaticFormGroup(
        items: [
          // Role first: a focus is created within a role, so it's the lead-in.
          roleField,
          FormTextInput(
            key: 'title',
            label: 'Focus name',
            required: true,
            initialValue: prefill?.title,
          ),
          // Description last (just above the buttons): it feeds thread matching,
          // so it reads as the lead-in to "Find matching threads".
          FormTextInput(
            key: 'description',
            label: 'Description',
            required: true,
            maxLines: 3,
            placeholder: 'What belongs in this focus?',
            initialValue: prefill?.description,
          ),
          _focusIconSelect(initial: prefill?.iconKey ?? 'bullseyePointer'),
          colorField,
```

- [ ] **Step 2: Reorder the edit form**

In `EditPriorityCommand`, the items list currently is `title`, `roleField`, icon, color. Move
`roleField` first. Change:

```dart
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Focus name',
                    initialValue: p.title,
                    required: true,
                  ),
                  roleField,
                  _focusIconSelect(initial: p.icon ?? 'bullseyePointer'),
                  colorField,
```

…to:

```dart
              StaticFormGroup(
                items: [
                  roleField,
                  FormTextInput(
                    key: 'title',
                    label: 'Focus name',
                    initialValue: p.title,
                    required: true,
                  ),
                  _focusIconSelect(initial: p.icon ?? 'bullseyePointer'),
                  colorField,
```

- [ ] **Step 3: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: "No issues found!"

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/priority.dart
git commit -m "feat(focus): Role field first on the create and edit focus forms"
```

---

## Task 5: Role chooser first; "Other" template; no "Suggestions" heading

Restructure `AddFocus` so it opens a role chooser, then the templates for the chosen role.
Rename the custom-focus row to "Other" at the bottom, and drop the group heading.

**Files:**

- Modify: `apps/plot/lib/command/priority.dart` — `AddFocus` (~686–731), `_CreateCustomFocus`
  (~733–748). `_CreateSuggestedFocus` (~750–767), `NewFocus` (~639–679), `_resolveInitialRole`,
  and `createRoleInline` are reused unchanged.

- [ ] **Step 1: Replace `AddFocus` and add `_showFocusTemplates`**

Replace the entire `AddFocus` class (the block starting at the `/// Entry point for "Add a
focus".` doc comment through the end of the `AddFocus` class, ~681–731) with:

```dart
/// Entry point for "Add a focus". Opens the role chooser first ("Choose a role
/// to add a focus") — the user picks an existing role or adds a new one — then
/// shows the focus templates for that role. Picking a template (or "Other")
/// opens the prefilled two-step [NewFocus] form with the role pre-selected.
class AddFocus extends Command {
  AddFocus({this.defaultRoleId})
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  /// Pre-highlighted in the role chooser (e.g. the sidebar's currently-selected
  /// focus's role); the user can still pick another. Null highlights the user's
  /// first role.
  final RoleId? defaultRoleId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final initialRole = await _resolveInitialRole(defaultRoleId);
    if (!context.mounted) return const CommandSkipped();

    // Step 1 — choose (or add) a role. Selecting an existing role pops with it;
    // the "Add role" row creates one (name + colour) and pops with the new role.
    final chosen = await SelectModal.open<Role>(
      context,
      title: 'Choose a role to add a focus',
      selectedValue: initialRole,
      items: (search) async {
        final roles = await Role.all();
        final filtered = search == null
            ? roles
            : roles
                  .where(
                    (r) =>
                        r.name.toLowerCase().contains(search.toLowerCase()),
                  )
                  .toList();
        return [
          SelectGroup<Role>(items: filtered),
          SelectGroup<Role>(
            items: <Role>[],
            infoBuilder: (ctx) => addItemRow(ctx, label: 'Add role'),
            onActivate: (ctx) async {
              final role = await createRoleInline(ctx);
              if (role != null && ctx.mounted) {
                Modal.pop<Role>(ctx, Value(role));
              }
            },
          ),
        ];
      },
      itemBuilder: (role, _) => Builder(
        builder: (ctx) => Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ctx.theme.spacing.lg,
            vertical: ctx.theme.spacing.md,
          ),
          child: Row(
            children: [
              ColorDot(color: role.displayColor),
              SizedBox(width: ctx.theme.spacing.md),
              Expanded(
                child: Text(role.name, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
    if (!chosen.present || !context.mounted) return const CommandSkipped();

    // Step 2 — choose a focus template (or "Other") for the chosen role.
    return _showFocusTemplates(chosen.value).run(context);
  }
}

/// Step-2 picker: the curated focus templates for [role], with "Other" last and
/// no group heading. When the user has dismissed every suggestion, skips
/// straight to the empty create form.
Command _showFocusTemplates(Role role) {
  return ShowCommands(
    title: 'Add a focus',
    icon: PlotIcon.add,
    commandsBuilder: (context) async {
      final dismissed = await DismissedFocusSuggestions.get();
      final suggestions = visibleFocusSuggestions(dismissed);
      return Commands(
        groups: [
          StaticCommandGroup(
            commands: [
              for (final s in suggestions)
                _CreateSuggestedFocus(s, defaultRoleId: role.id),
              _CreateOtherFocus(defaultRoleId: role.id),
            ],
          ),
        ],
      );
    },
  );
}
```

Notes for the implementer:

- `SelectModal`, `SelectGroup`, `Modal`, `ColorDot`, `addItemRow`, `ShowCommands`,
  `Commands`, `StaticCommandGroup` are all already reachable in this file.
- The empty-suggestions case is handled implicitly: when `suggestions` is empty the picker
  shows only "Other", which opens the empty `NewFocus` form — equivalent to skipping to it.
- Selecting a role pops via `SelectModal`'s default `_selectItem` (no `onSelect` needed); the
  "Add role" row pops via its `onActivate`. Both resolve `SelectModal.open` with a `Role`, so
  `chosen.value` is always the role to build templates for.

- [ ] **Step 2: Rename `_CreateCustomFocus` → `_CreateOtherFocus` ("Other")**

Replace the `_CreateCustomFocus` class (~733–748) with:

```dart
/// "Other" row — opens the empty two-step create form. Sits last in the
/// templates list as the catch-all.
class _CreateOtherFocus extends Command {
  _CreateOtherFocus({this.defaultRoleId})
    : super(
        title: 'Other',
        subtitle: "Describe anything you'd like to focus on",
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final RoleId? defaultRoleId;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      NewFocus(defaultRoleId: defaultRoleId).run(context);
}
```

(Leave `_CreateSuggestedFocus` unchanged — it already renders `suggestion.title` /
`suggestion.description` and forwards `defaultRoleId`.)

- [ ] **Step 3: Verify it analyzes (catches any leftover `_CreateCustomFocus` reference)**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: "No issues found!" If analyze reports an undefined `_CreateCustomFocus`, grep for it
(`grep -n _CreateCustomFocus lib/command/priority.dart`) and remove the stray reference.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/priority.dart
git commit -m "feat(focus): choose a role first, then templates; 'Other' replaces custom focus"
```

---

## Task 6: Whole-flow analyze, manual verification, and docs

**Files:**

- Modify: `docs/updates.md` (user-facing changelog)
- Modify: `docs/features.md` if the focus-creation description needs refreshing

- [ ] **Step 1: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: "No issues found!"

- [ ] **Step 2: Run the focus-suggestions tests**

Run: `cd apps/plot && flutter test test/command/focus_suggestions_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 3: Manual verification via the `run-app` skill**

Launch the app (invoke the `run-app` skill) and verify:

1. Tap "Add a focus" (sidebar) → a modal titled **"Choose a role to add a focus"** lists the
   user's roles, with the currently-selected focus's role highlighted, and an **"Add role"**
   row at the bottom.
2. Pick a role → the **focus templates** appear with **no "Suggestions" heading**; the dropped
   templates (Volunteering, Personal admin, Promotions) are absent; **"Other"** (subtitle
   "Describe anything you'd like to focus on") is the **last** row.
3. Pick a template → the create form opens with the **Role field first**, pre-selected to the
   chosen role.
4. From the role chooser, pick **"Add role"** → name+colour form → creating a role advances to
   the templates for that new role.
5. Open **Edit focus** on an existing focus → the **Role field is first**, and its picker shows
   the **"Add role"** labeled row (not just a "+").
6. Esc behaves sanely at each step (dismisses the current modal).

- [ ] **Step 4: Update docs**

Add to `docs/updates.md` under `## Next release` (create the heading at the very top if absent),
in a `### Focuses` section (create it above any `### Fixes`):

```markdown
- Creating a focus now starts by choosing the role it belongs to (or adding a new
  role), then a focus template.
```

Skim `docs/features.md` for the focus-creation description; if it describes the old
"suggestions" picker, update that sentence to mention choosing a role first. (Keep edits
minimal and factual.)

- [ ] **Step 5: Markdown lint the docs you touched**

Run: `pnpm format:md && pnpm lint:md`
Expected: `Summary: 0 error(s)`.

- [ ] **Step 6: Commit**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: focus creation starts by choosing a role"
```

---

## Self-review notes (spec coverage)

- Drop Volunteering / Personal admin / Promotions → Task 1. ("Reading" intentionally kept.)
- "Other" + subtitle, drop "Suggestions" heading, "Other" last → Task 5.
- First modal = `SelectModal` "Choose a role to add a focus", roles + "Add role" → Task 5
  (with the shared row from Task 2).
- After selecting a role, show templates → Task 5 (`_showFocusTemplates`).
- Role field first on create + edit → Task 4.
- Same role-selection modal in all three places (new step-1 + create + edit Role fields), each
  offering choose-existing or add+select (name + colour) → Tasks 2 + 3 + 5.

## Risk / fallback

The new flow is sequential: selecting/adding a role in step 1 closes that modal, then the
templates picker opens (`_showFocusTemplates(...).run(context)`). This matches the existing
`AddFocus → templates → NewFocus` chaining and avoids depending on nested-modal back-stacking.
If product wants Esc from the templates to return to the role chooser (rather than dismiss),
that's a follow-up that would keep the chooser mounted via `onSelect` returning `false` and
running the templates command inline — out of scope for this plan.
