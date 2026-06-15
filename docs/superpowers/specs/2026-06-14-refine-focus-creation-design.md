# Refine the focus creation process

## Background

Focus creation today (`AddFocus` in `apps/plot/lib/command/priority.dart`) opens a
command picker with a "Create a custom focus" row plus a **Suggestions** group of curated
focus templates (`kFocusSuggestions` in `command/focus_suggestions.dart`). Picking a
template opens the two-step `NewFocus` form (details → matching threads). The form already
carries a **Role** field, because focuses are now grouped under roles
(`command/role.dart`, `store/role.dart`).

Two recently shipped features make parts of this flow redundant:

- **Roles** (#288) group focuses under a role, so generic life-area templates like
  _Volunteering_ and _Personal admin_ are better expressed as roles.
- **FYI focus** (#291) routes low-signal content (promotions, reading, receipts,
  notifications), so a _Promotions_ focus template is redundant.

This change refines the creation flow so the user **chooses a role first**, then a focus
template, and unifies the role-selection modal across the three places it appears.

## Goals

1. Drop the `volunteering`, `personal_admin`, and `promotions` focus templates.
2. Replace the "Create a custom focus" row with **"Other"** (subtitle "Describe anything
   you'd like to focus on") and drop the **Suggestions** group heading; "Other" sits last.
3. Make the first modal a `SelectModal` titled **"Choose a role to add a focus"** that lists
   the user's existing roles plus an **"Add role"** row.
4. After a role is chosen (or created), show the focus templates for that role.
5. Put the **Role** field first on the create and edit focus modals.
6. Use the **same role-selection modal in all three places**: the new first step, and the
   Role field inside both the create and edit focus modals. In each, the user either picks
   an existing role or adds-and-selects a new one (choosing its name and colour).

## Non-goals

- No change to onboarding's role question (`widget/onboarding/onboarding_role.dart`); it has
  its own role list and is out of scope.
- No change to the two-step `NewFocus` matching step, role propagation triggers, or the
  server `/sync/roles` API.
- The `reading` template is **kept**. Only the three templates named above are dropped.

## New flow

"Add a focus" (the single sidebar tile in `widget/priorities_list.dart`, or the command
palette entry in `command/global.dart`) opens a three-step, back-navigable flow:

1. **Choose a role** — a `SelectModal<Role>` titled "Choose a role to add a focus". Lists
   existing roles (via `Role.all()`), with a labeled **"Add role"** row at the bottom. The
   currently-selected focus's role (today's `defaultRoleId`, i.e. `selected?.roleId`) is
   pre-highlighted as `selectedValue`. There is always at least one role post-#288
   (seeded "Personal"), so the list is never empty.
   - Pick a role → step 2 with that role.
   - Pick "Add role" → the existing `AddRole` name+colour form (`createRoleInline`), then
     step 2 with the new role.
2. **Choose a focus** — the templates picker (a `ShowCommands`), with **no** group heading:
   a single untitled group of the curated templates, then **"Other"** last (subtitle
   "Describe anything you'd like to focus on"). If the user has dismissed every suggestion,
   skip straight to step 3.
   - Pick a template → step 3, prefilled from the template.
   - Pick "Other" → step 3, empty.
3. **Create form** — the existing two-step `NewFocus` form, with the chosen role
   pre-selected in its (now first) Role field.

Esc/back unwinds 3 → 2 → 1, mirroring how the templates → form steps already nest today.

## Changes by area

### 1. Template list — `command/focus_suggestions.dart`

Remove three `FocusPrefill` entries from `kFocusSuggestions`: `volunteering`,
`personal_admin`, `promotions`. The eight survivors keep their keys and source order:
`project`, `customers`, `operations`, `management`, `recruiting`, `admin`, `reading`,
`social`. Per the list's own maintenance note, deleting entries leaves any stored dismissals
of those keys as harmless orphans, so no migration is needed.

`focus_suggestions_test.dart` asserts only key-uniqueness and filter behaviour (it never
names a specific template), so it is unaffected.

### 2. Templates picker — `command/priority.dart`

In the templates `ShowCommands`:

- Rename `_CreateCustomFocus` to render as title **"Other"**, subtitle **"Describe anything
  you'd like to focus on"**.
- Move "Other" to the **bottom**, after the suggestions.
- Drop the `title: 'Suggestions'` header — put suggestions and "Other" in a single untitled
  `StaticCommandGroup` (or two untitled groups), so no heading shows.

### 3. Shared role-selection modal

The role picker must look and behave the same in all three places.

**`FormSelect` enhancement (`widget/form.dart`):** add an optional `addLabel` (and optional
`addIcon`, defaulting to `PlotIcon.add`). When `addLabel` and `onAdd` are both set, the
picker renders a keyboard-navigable **labeled row** at the bottom of the list instead of the
subtle "+" search-field button. Implementation reuses `SelectModal`'s existing info-only
group mechanism: `FormSelect.activate` appends a trailing `SelectGroup<T>` with empty
`items`, an `infoBuilder` that renders the "Add …" row, and an `onActivate` that runs
`onAdd` and, on a non-null result, pops the modal with that value
(`Modal.pop<T>(context, Value(result))`). When `addLabel` is set, do not also pass `onAdd`
straight through to the "+" button — the row is the single add affordance. This stays
generic over `T`; only the Role field opts in.

**Create/edit Role field (`_roleSelect` in `command/priority.dart`):** pass
`addLabel: 'Add role'`. Both the create and edit focus modals' Role pickers then show the
labeled "Add role" row, wired to the existing `createRoleInline` (name + colour).

**New step-1 modal:** uses `SelectModal<Role>` directly, with the same roles list and an
"Add role" row, so it matches the Role-field pickers. Because its "Add role" continues to
step 2 (rather than popping a value back to a form field), it builds the trailing info-group
itself with an `onActivate` that calls `createRoleInline` then advances to the templates.

A small shared helper (e.g. in `command/role.dart`) builds the "Add role" row widget so the
`FormSelect` path and the standalone modal render it identically.

### 4. Form field order — `command/priority.dart`

Move the Role field to **first** in both forms:

- `_buildFocusDetailsForm` (create): `role, title, description, icon, color, …buttons`.
- `EditPriorityCommand` (edit): `role, title, icon, color, save`.

The description's "just above the buttons" relationship is preserved (it still feeds thread
matching). The Role field keeps its colour-follow preview (`onChanged` updates the colour
field when the focus is still following the role's colour).

### 5. `AddFocus` restructure — `command/priority.dart`

`AddFocus({defaultRoleId})` now:

1. Resolves the pre-highlight role from `defaultRoleId` (`_resolveInitialRole`).
2. Opens the step-1 `SelectModal<Role>` ("Choose a role to add a focus").
3. On a role being chosen or added, shows the templates picker for that role (threading the
   role through `NewFocus`/`AddPriority` via `defaultRoleId`), or skips to `NewFocus`
   directly when no suggestions remain.

The sidebar tile and command-palette entry keep their current call sites; only the internals
of `AddFocus` change. The existing suggestion-dismissal recording (`DismissedFocusSuggestions`
keyed on `suggestionKey`) is unchanged.

## Data / API

None. No schema, migration, sync, or Twister changes. All edits are Flutter-client UI and
command wiring over existing `Role` and `Priority` stores.

## Testing

- **Unit (pure):** `focus_suggestions_test.dart` continues to pass unchanged; optionally add
  an assertion that the three dropped keys are absent.
- **Widget/flow:** a test driving `AddFocus` → role chooser (existing role highlighted) →
  templates ("Other" present and last, no "Suggestions" heading) → create form (Role field
  first, pre-selected). Cover the "Add role" path creating and selecting a new role.
- **Manual (`run-app`):** verify all three role modals match; verify Esc back-navigation; the
  dropped templates no longer appear; "Other" subtitle renders.
- `flutter analyze` clean.

## Risks / open points

- **Nested back-navigation** (step 3 → 2 → 1) relies on running commands from inside the
  `SelectModal.onSelect`/info-row `onActivate` while the chooser stays mounted. This mirrors
  the existing templates → form nesting and the `onSelect: context.run(...)` precedent in
  `widget/unified_header.dart`. If it proves fiddly, the fallback is sequential modals (the
  chooser pops on selection; no back-to-chooser), which still satisfies the spec's "after
  selecting a role, display the focus templates".
- **`addLabel` info-row in `FormSelect`** is a generic enhancement; gate it behind the new
  optional param so all other `FormSelect` usages are unchanged.
