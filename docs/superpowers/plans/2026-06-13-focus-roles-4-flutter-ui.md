# Focus Roles — Plan 4: Flutter UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Surface roles in the UI: an accordion sidebar that nests focuses under collapsible role headers (only when there's >1 role), with animated expand/collapse, reverse-inherited status on collapsed roles, drag-reorder of both roles and focuses, and an "Edit role / Notifications" role menu; a **Role** field in the focus create/edit modal with an inline **Add role** modal; and a role-level **Notifications** editor.

**Architecture:** Two parts. **Part A (state + sidebar):** `PrioritiesBloc` also exposes the user's roles; the sidebar groups focuses by `roleId`. With ≤1 role it renders exactly as today (flat). With >1 role it renders an outer reorderable list of role headers, each expanding (animated) to an inner reorderable list of its focuses; the expanded role is derived from the selected focus's `roleId` (a pure accordion, no persisted expand state). **Part B (modals):** add a `FormSelect<Role>` to the focus form (+ inline Add role modal), and a role variant of the notifications editor; wire both into a role "…" menu. Reverse-inherit and "expanded = selected focus's role" are computed client-side.

**Tech Stack:** Flutter + forui (`apps/plot/lib/widget`, `state`, `command`); `flutter analyze` is the gate; `run-app` for visual verification where possible. Roles come from `Role` (Plan 3); focuses carry `roleId`/`isInbox`.

**This plan is Plan 4 of 6.** Plans 1–3 landed. Branch `focus-roles`.

---

## Key existing pieces (verified)
- `apps/plot/lib/widget/priorities_list.dart` — sidebar build; `ReorderableListView<Priority>` (lines 92–111); `_onReorderFocus` (201–221, uses `Order.between`); fixed Inbox + Everything tiles currently OUTSIDE the scrollable (155–194); "Add a focus" tile inside scroll (123–136); `_byOrder` sorter (39–42); `monochrome`/`selected` logic.
- `apps/plot/lib/widget/priority.dart` `PriorityWidget` — already has `expandable`/`expanded`/`onToggleExpand` + `_ExpandCaretButton` (357–399), `boldActive`, `PriorityNotification` unread dot (322–331), trailing "…" `Button.icon(ShowPriorityCommands(priority))` on hover (196–219).
- `apps/plot/lib/widget/reorderable_list_view.dart` — custom generic `ReorderableListView<T>` (`list`, `itemBuilder(ctx,item,reorderableIndex)`, `onReorder`, `keyExtractor`, `shrinkWrap`).
- `apps/plot/lib/widget/animated_removal.dart` — `SizeTransition` + optional `FadeTransition` disclosure pattern to reuse for expand/collapse.
- State: `NowBloc.setContext(priority, …)` / `NowLoaded.context` (selected focus); `PrioritiesBloc`/`PrioritiesState` (`priorities`, `root`).
- `command/priority.dart`: `EditPriorityCommand` (1220–1285), `_buildFocusDetailsForm`, `NewFocus`/`AddFocus`, `prioritySecondaryCommands` (1426–1432), `_focusIconSelect`.
- `command/early_notifications.dart`: `ShowEarlyNotificationsSettings` + `_buildForm` (194–313) + `_SaveEarlyNotifications` (443–556).
- `util/theme_color.dart` (`ThemeColor.options`, `.defaultColor()`), `widget/color_dot.dart` (`ColorDot`), `widget/form.dart` `FormSelect` (`onAdd`, `leadingBuilder`, `gridColumns`).
- `store/role.dart`: `Role.watch/all/getOne/save`, `displayColor`, `notifyWindows`, `seeWithinTime`.

---

# PART A — State + Sidebar accordion

## Task A1: Expose roles + grouping in `PrioritiesBloc`

**Files:** `apps/plot/lib/state/priorities.dart`, `priorities_state.dart`

- [ ] **Step 1: Add `roles` to the state**

Read both files. Add `List<Role> roles` to `PrioritiesState` (default `const []`, include in `copyWith`/`props`). In `PrioritiesBloc`, subscribe to `Role.watch()` (alongside the existing `Priority.watch()` subscription) and emit `roles` on change. Cancel the subscription in `close()` like the priorities one.

- [ ] **Step 2: Add grouping helpers**

Add to `PrioritiesState` (or a small helper):
```dart
/// Non-archived focuses for [roleId], sorted by order with the Inbox last.
List<Priority> focusesForRole(RoleId roleId) {
  final list = priorities.where((p) => p.roleId == roleId && p.archivedAt == null).toList()
    ..sort((a, b) {
      if (a.isInbox != b.isInbox) return a.isInbox ? 1 : -1; // Inbox last
      final c = a.order.value.compareTo(b.order.value);
      return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
    });
  return list;
}

/// Roles sorted for the sidebar (by order, then createdAt).
List<Role> get sortedRoles {
  final live = roles.where((r) => r.archivedAt == null).toList()
    ..sort((a, b) {
      final c = (a.order ?? 0).compareTo(b.order ?? 0);
      return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
    });
  return live;
}
```

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/state/`
Expected: no new errors.

---

## Task A2: Role header widget (collapsed reverse-inherit + caret + "…" menu)

**Files:** Create `apps/plot/lib/widget/role_header.dart`

- [ ] **Step 1: Build the header widget**

A stateless widget rendering one role header row: role name in `role.displayColor` (muted, matching `focusStyle`'s muted treatment), a leading caret (`_ExpandCaretButton`-style chevron: down when expanded, right when collapsed), and — when **collapsed** — reverse-inherited status from its focuses:
- **bold** if any focus in the role would be bold (`focus.active`),
- a **notification dot** (`PriorityNotification(unread: true, color: role.displayColor)`) if any focus is unread.

Params: `role`, `expanded`, `childFocuses` (to compute reverse-inherit), `monochrome`, `onTap` (tap header), `onMenu` (… menu). On tap, call `onTap`. Show the "…" `Button.icon(ShowRoleCommands(role))` on hover (mirror `PriorityWidget`'s hover-reveal at 196–219). Reuse `_ExpandCaretButton` (extract it from `priority.dart` to a shared spot if needed, or duplicate its tiny body).

```dart
final anyActive = childFocuses.any((f) => f.active);
final anyUnread = childFocuses.any((f) => f.unread);
final bold = !expanded && anyActive;
final showDot = !expanded && anyUnread;
```

> Keep this widget stateless except local hover state (like `PriorityWidget`). Bloc state is passed in by the page, not read here (project rule).

---

## Task A3: Accordion sidebar render + animation + nested reorder

**Files:** `apps/plot/lib/widget/priorities_list.dart`

- [ ] **Step 1: Move "Everything" inside the scrollable**

Per the design change: the "Everything" row becomes the LAST row inside the scrollable, AFTER the "Add a focus" tile. Remove the old fixed bottom "Inbox" `FixedFocusTile` entirely (per-role Inboxes replace it). Remove the fixed "Everything" tile from below the scroll and render it as the final in-scroll row instead. (Keep the same `FixedFocusTile`/tile widget, just relocated.)

- [ ] **Step 2: Branch on role count**

Read `PrioritiesBloc` state (`sortedRoles`). Compute `expandedRoleId = nowState.everything ? null : (selectedFocus?.roleId)`.

- **If `sortedRoles.length <= 1`:** render exactly as today — a flat `ReorderableListView<Priority>` over `focusesForRole(theOnlyRole.id)` (Inbox last), then "Add a focus", then "Everything". (Falls back to the current flat behavior; no role header.)
- **If `sortedRoles.length > 1`:** render an **outer** `ReorderableListView<Role>` over `sortedRoles`. Each item is a `Column` of:
  1. `RoleHeader(role, expanded: role.id == expandedRoleId, childFocuses: focusesForRole(role.id), onTap: …, …)`.
  2. An **animated** disclosure containing, when `role.id == expandedRoleId`, an **inner** `ReorderableListView<Priority>` over `focusesForRole(role.id)` rendered with a slight left indent. Wrap the inner list in an `AnimatedSize` (or `SizeTransition` + `FadeTransition`, reusing the `animated_removal.dart` pattern) so expand/collapse animates (caret rotation + focuses sliding/fading). Because it's an accordion, switching `expandedRoleId` animates the previous role closed and the new one open.

  Below the outer list: the "Add a focus" tile, then "Everything".

- [ ] **Step 2 detail: tap behaviors**
  - Tapping a **collapsed** role header → select its **first** focus (`focusesForRole(role.id).first`, i.e. first by order; Inbox is last) via the existing focus-tap command (`ChangeCurrentPriority`/`buildContext.run`). That selection makes the role the `expandedRoleId`, which animates it open.
  - Tapping an **expanded** role header → no-op (or re-select its first focus); do not collapse to nothing (accordion always keeps the selected role open). Simplest: header tap always selects the role's first focus.

- [ ] **Step 3: Reorder callbacks**
  - **Outer (roles):** `onReorder` computes the new `role.order` via `Order.between(prev?.order, next?.order)` and `role.save()`. Mirror `_onReorderFocus` but for roles (add `_onReorderRole`).
  - **Inner (focuses within a role):** reuse `_onReorderFocus` over that role's `focusesForRole` list (it already uses `Order.between` + `priority.save()`). Reordering stays within the role (no cross-role drag — out of scope).

- [ ] **Step 4: New-focus default role**

The "Add a focus" tile (`AddFocus()`): pass the current `expandedRoleId` (the selected role) so the new focus defaults to that role. (Wire in Part B's role field default — for now ensure `AddFocus`/`NewFocus` can accept an optional `defaultRoleId`.)

- [ ] **Step 5: Analyze + run-app**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors. Then attempt a visual check via the `run-app` skill: with 2+ roles, confirm headers appear, only the selected focus's role is expanded, collapsing/expanding animates, a collapsed role with an unread/active child shows the dot/bold, dragging a role reorders it, dragging a focus reorders within its role, and "Everything" is the last in-scroll row. If `run-app` is blocked (e.g. Clerk session), note it and rely on analyze + any widget tests.

---

## Task A4: Role "…" menu commands

**Files:** `apps/plot/lib/command/priority.dart` (or a new `command/role.dart`)

- [ ] **Step 1: Add `ShowRoleCommands` + the menu**

Create a `ShowRoleCommands(role)` `Commands` (mirror `ShowPriorityCommands`) whose items are:
```dart
List<Command> roleSecondaryCommands(Role role) => [
  EditRoleCommand(role),                 // Part B Task B2
  ShowRoleNotificationsSettings(role),   // Part B Task B3
];
```
(`EditRoleCommand` / `ShowRoleNotificationsSettings` are defined in Part B; if executing Part A first, stub them to `AddRole`-style placeholders that Part B fills, or implement Part B's B2/B3 before wiring this menu. Prefer implementing Part B before A4's final wiring.)

---

# PART B — Focus modal Role field, Add role, Role notifications

## Task B1: Role field + Add role modal in the focus form

**Files:** `apps/plot/lib/command/priority.dart`; Create `apps/plot/lib/command/role.dart`

- [ ] **Step 1: Add an Add role modal**

In `command/role.dart`, add `AddRole` (a `ShowForm`) collecting **name + colour only** (no notifications), returning the created `Role`:
```dart
class AddRole extends ShowForm {
  AddRole({this.onCreated})
    : super(
        title: 'Add a role',
        icon: PlotIcon.add,
        form: (context) async => FormData(
          title: 'Add a role',
          groups: [StaticFormGroup(items: [
            FormTextInput(key: 'name', label: 'Role name', required: true),
            FormSelect<ThemeColor>(
              key: 'color', label: 'Color',
              initialValue: const ThemeColor(0), hasInitialValue: true,
              items: (s) async => ThemeColor.options.where((c) =>
                s == null || c.label.toLowerCase().startsWith(s.toLowerCase())).toList(),
              titleBuilder: (c) => c.label, leadingBuilder: (c) => ColorDot(color: c),
            ),
            FormButton(key: 'create', isPrimary: true, buildCommand: (v) => _CreateRole(
              name: v['name'] as String, color: v['color'] as ThemeColor, onCreated: onCreated)),
          ])],
        ),
      );
  final void Function(Role)? onCreated;
}
```
`_CreateRole` builds a `Role` (client-generated id via the table's UuidTable default, `name`, `color`, `order` = now-millis) and `await role.save()` (pushes to `/sync/roles`; the server auto-creates its Inbox). Then `onCreated?.call(role)` and return `CommandDone`. Provide an inline helper `createRoleInline(context, name, color)` returning the created `Role` for the `FormSelect.onAdd` path (mirror `createPriorityInline`).

- [ ] **Step 2: Add the Role `FormSelect` to the focus form**

In `EditPriorityCommand`'s form (and `_buildFocusDetailsForm` for create), add a **required** Role field above or near the colour field:
```dart
FormSelect<Role>(
  key: 'role',
  label: 'Role',
  initialValue: /* the focus's current role (Role.getOne(p.roleId)) or the default role */,
  hasInitialValue: true,
  items: (search) async => (await Role.all()).where((r) =>
    search == null || r.name.toLowerCase().contains(search.toLowerCase())).toList(),
  titleBuilder: (r) => r.name,
  leadingBuilder: (r) => ColorDot(color: r.displayColor),
  onAdd: (ctx) async => await createRoleInline(ctx),   // opens AddRole, returns the new Role
  onChanged: (role) { /* see Step 3 */ },
),
```
The form's save (`EditPriority`/`AddPriority`) must set `roleId = selectedRole.id` on the focus so the push sends `role_id` (the server's `apply_role_change_to_focus` trigger applies follow-if-matching). Read how the existing form reads field values into the save command and thread `role` through.

- [ ] **Step 3: Modal colour follows role on change**

When the user changes the **Role** field, update the **Colour** field's value to the new role's colour **iff** the focus was following its old role (current colour == old role's colour). If the colour was an override (differs), leave it. This previews the server's follow-if-matching. Implement via `onChanged` calling the form's field-set API (check how `FormSelect.onChanged` + the form scope let you set another field's value; if the form framework can't set a sibling field, document it and rely on the server trigger to correct on save — but prefer the live preview). Compare against the role loaded for the focus's current `roleId`.

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/`
Expected: no new errors.

---

## Task B2: Edit role modal

**Files:** `apps/plot/lib/command/role.dart`

- [ ] **Step 1: `EditRoleCommand`**

A `ShowForm` editing an existing role's **name + colour** (notifications live in the separate notifications modal, B3). On save, set `name`/`color` and `role.save()`. Changing the colour fires the server's `propagate_role_to_focuses` trigger (following focuses adopt it). Mirror `EditPriorityCommand`'s structure.

```dart
class EditRoleCommand extends ShowForm {
  EditRoleCommand(Role role) : super(title: 'Edit role', icon: PlotIcon.settings,
    form: (context) async {
      final r = await Role.getOne(role.id) ?? role;
      return FormData(title: 'Edit role', groups: [StaticFormGroup(items: [
        FormTextInput(key: 'name', label: 'Role name', initialValue: r.name, required: true),
        FormSelect<ThemeColor>(key: 'color', label: 'Color', initialValue: r.displayColor,
          hasInitialValue: true, items: (s) async => ThemeColor.options.where((c) =>
            s == null || c.label.toLowerCase().startsWith(s.toLowerCase())).toList(),
          titleBuilder: (c) => c.label, leadingBuilder: (c) => ColorDot(color: c)),
        FormButton(key: 'save', isPrimary: true, buildCommand: (v) => _SaveRole(role.id,
          name: v['name'] as String, color: v['color'] as ThemeColor)),
      ])]);
    });
}
```
`_SaveRole`: load the role, `copyWith(name, color)`, `save()`.

---

## Task B3: Role notifications modal

**Files:** Create `apps/plot/lib/command/role_notifications.dart` (or extend `early_notifications.dart`)

- [ ] **Step 1: Build the role notifications editor**

Mirror `ShowEarlyNotificationsSettings`/`_buildForm`/`_SaveEarlyNotifications` from `early_notifications.dart`, but bound to a **Role**: edit `early_notifications_enabled` (FormToggle), `notify_window` (FormWindowList), `see_within` (FormSelect<SeeWithinTime>). There is NO inheritance/`*_set` logic for roles (a role's values are absolute), so the save is simpler than the priority version: just write the three fields onto the role and `role.save()` (pushes `/sync/roles`; the server's `propagate_role_to_focuses` updates following focuses). Title: `'Notifications for ${role.name}'`.

```dart
class ShowRoleNotificationsSettings extends ShowForm {
  ShowRoleNotificationsSettings(this.role) : super(title: 'Notifications', icon: PlotIcon.notification,
    form: (context) => _build(context, role));
  final Role role;
}
```
The save command loads the role, `copyWith(earlyNotificationsEnabled, notifyWindow: jsonEncode(windows), seeWithin: jsonEncode(seeWithin))`, `save()`. Reuse `FormWindowList` and the `_seeWithinOptions` from `early_notifications.dart` (import or factor out the shared `SeeWithinTime` option list rather than duplicating it).

- [ ] **Step 2: Wire the role "…" menu (finish Task A4)**

Now that `EditRoleCommand` + `ShowRoleNotificationsSettings` exist, finalize `roleSecondaryCommands` (Task A4) to reference them.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

---

## Task B4: Verify + Commit

- [ ] **Step 1: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors (note pre-existing warnings).

- [ ] **Step 2: run-app visual check (best-effort)**

Use the `run-app` skill to verify end-to-end where possible: create a second role via the focus modal's Add role → sidebar shows role headers; the new role has an Inbox; edit a focus's role and confirm its colour follows (if it matched) or stays (if overridden); open a role's "…" → Edit role (rename/recolor → following focuses recolor) and Notifications. If blocked by Clerk/login, document and rely on analyze.

- [ ] **Step 3: Commit**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
git add -A apps/plot/lib/
git commit --no-verify -m "feat(app): role accordion sidebar + Role field + Add role + role notifications

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (run before execution)
- **Spec coverage:** ≤1 role → unchanged flat sidebar ✓ (A3); >1 role → indented accordion, only selected focus's role expanded ✓ (A3); animated expand/collapse ✓ (A3 Step 2); collapsed reverse-inherit bold + dot ✓ (A2); click collapsed role → select first focus ✓ (A3 detail); role "…" = Edit role + Notifications ✓ (A4/B2/B3); Everything in-scroll after Add a focus, old Inbox tile removed ✓ (A3 Step 1); drag-reorder roles + focuses-within-role ✓ (A3 Step 3); Role field + Add role modal ✓ (B1); modal colour-follows-role preview ✓ (B1 Step 3); role colour/notif edits propagate via server triggers ✓ (B2/B3). Backfill/onboarding are Plans 1/5; path/root teardown + v5 is Plan 6.
- **No placeholders:** behavior is concrete; the "read X then thread the value through" notes (B1 save wiring, B3 shared see-within options, A3 nested reorderable) are genuine integration points requiring the current code.
- **Type consistency:** `Role`, `roleId`, `isInbox`, `expandedRoleId`, `focusesForRole`, `sortedRoles`, `RoleHeader`, `ShowRoleCommands`, `AddRole`, `EditRoleCommand`, `ShowRoleNotificationsSettings` used consistently across tasks.
- **Risk:** nested `ReorderableListView` (outer roles, inner focuses) is the hardest piece — if the custom widget can't nest cleanly, keep roles reorderable and focuses reorderable within the one expanded role as separate instances (still satisfies the spec); document any limitation.
