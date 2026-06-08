# NewThreadPage contact/group add + edit UI

**Date:** 2026-06-08
**Status:** Approved design, pending implementation plan
**Builds on:** `2026-06-07-user-contacts-groups-apis-design.md` (the headless write commands `AddContact`/`RenameContact`/`CreateGroup`/`RenameGroup`/`AddGroupMembers`/`RemoveGroupMembers` and the offline `/sync/{actors,groups}` path).

## Summary

Add UI on the NewThreadPage step-1 picker to create and edit contacts and groups:

1. **Row "… More" menu** — contact, group, and ad-hoc-multi-contact rows get a trailing "…" button on hover (and via Cmd+Enter on the highlighted row). It opens a one-item command menu: **Edit contact** / **Edit group**.
2. **Header ghost buttons** — the "People and twists" section header gets "+ Contact" and "+ Group" ghost buttons (styled exactly like the existing "+ Topic" button in the Channels header) that open create forms.

Both affordances open `FormModal`s and dispatch the existing offline write commands. "Multiple selected contacts" are treated as a group: naming an ad-hoc multi-contact set creates a real group.

## Scope

In scope:
- Trailing "…" affordance on contact / group / ad-hoc-group rows in the step-1 `PillGrid` (hover + Cmd+Enter), opening a `CommandModal` with one item.
- New UI commands `NewContact`, `EditContact`, `EditGroup` that show `FormModal`s and dispatch the existing write commands.
- "+ Contact" and "+ Group" ghost buttons in the "People and twists" header.
- Allow `AddContact` with an empty/omitted name (email-only contact).
- Command-level unit tests + `flutter analyze`.

Out of scope:
- Editing a contact's email (no backend; per-user name only).
- Twist / channel / focus rows getting the affordance.
- Adding email-only invitees (no contact id) as group members.
- Run-app / visual verification (consistent with the rest of this feature).
- An anchored popover-menu primitive (using the existing `CommandModal`; an anchored popover is a future polish).

## Existing patterns to mirror (do not reinvent)

- **Step-1 sections view**: `apps/plot/lib/widget/compose/compose_sections_view.dart`. Builds `PillGridSection`s. `_channelsHeader()` renders a right-aligned `FButton(variant: FButtonVariant.ghost, style: ghostSizedStyleDelta(...))` "+ Topic" shown only when `onCreateTopic != null`; `_onCreateTopicPressed()` calls the page callback and on success reloads sections. `_peopleHeader()` is currently a plain `_sectionHeader('People and twists')`.
- **Row grid**: `apps/plot/lib/widget/compose/pill_grid.dart`. `PillGrid` renders `PillGridItem { data: ComposePillData, onActivate }` rows wrapped in `_rowChrome(highlighted, child)` with `MouseRegion(onEnter: _setHighlight(index))`. `_highlighted` tracks the highlighted row index. No trailing affordance today.
- **Pill data** (sealed): `apps/plot/lib/widget/compose/compose_pill.dart` — `ContactPillData(actor)`, `GroupPillData(group, members)`, `AdHocGroupPillData(actors, {inviteEmails})`, plus twist/channel/focus variants.
- **Command menu**: `apps/plot/lib/widget/command_modal.dart` — `CommandModal(Commands, rootContext: ...).run(context)`.
- **Forms**: `apps/plot/lib/widget/form_modal.dart` (`FormModal`), `apps/plot/lib/widget/form.dart` (`FormTextInput`, `FormShareSelect`). Keyboard nav (Tab/↑↓/Enter/Esc) is built in.
- **Create-something-from-a-header-button** reference: `CreateTopic` (`apps/plot/lib/command/topic.dart`) + the page's `onCreateTopic` callback.
- **Write commands** (already built): `AddContact({name, email})`, `RenameContact({contactId, name})` in `command/contact.dart`; `CreateGroup({name, privacy, memberContactIds})`, `RenameGroup({groupId, name})`, `AddGroupMembers({groupId, contactIds})`, `RemoveGroupMembers({groupId, contactIds})` in `command/group.dart`.

## Commands (new, UI-launching)

These are the user-facing actions (the app convention: every user action is a `Command`). They show a `FormModal` and dispatch the headless writes.

### `EditContact` (`command/contact.dart`)
- Args: `contactId: ActorId`, `name: String` (current), `email: String?`.
- `run()`: `FormModal` with one `FormTextInput` "Name" (prefilled with `name`) and the email shown read-only (a disabled/label field). On submit with a non-empty, changed name → `RenameContact(contactId: contactId, name: newName)`. Esc/no-change → `CommandSkipped`.

### `NewContact` (`command/contact.dart`)
- Args: none (optional `initialEmail`/`initialName` for future reuse — omit for now).
- `run()`: `FormModal` with "Name" (optional) + "Email" (required) `FormTextInput`s. On submit → `AddContact(name: name, email: email)`. Validate email is non-empty and roughly well-formed (the server also validates; surface a `CommandMessage` on empty email rather than a failed write).

### `EditGroup` (`command/group.dart`)
- Args: `groupId: Uuid?` (null = create), `name: String` (prefill, '' for new/ad-hoc), `memberContactIds: List<Uuid>` (prefill).
- `run()`: `FormModal` with "Name" `FormTextInput` (prefilled) + a members `FormShareSelect` (prefilled with `memberContactIds`). On submit:
  - `groupId == null` → `CreateGroup(name: name, memberContactIds: selectedMembers)`.
  - `groupId != null` → if name changed: `RenameGroup(groupId, name)`; compute the membership diff (added/removed) vs the prefilled set and call `AddGroupMembers`/`RemoveGroupMembers` with the contact-id deltas (as `List<String>` of uuid strings, matching their existing signatures).
- Used by: the row menu (existing group → `groupId` set; ad-hoc → `groupId` null + members prefilled) and the header "+ Group" button (`groupId` null, empty name, empty members → `CreateGroup`).

`title` per command drives the `CommandModal` label: "Edit contact" / "Edit group".

## Row "… More" menu

- Extend `PillGridItem` with `final VoidCallback? onMore;`.
- In `PillGrid`, when a row is highlighted (`index == _highlighted`) AND `item.onMore != null`, render a trailing "…" `FButton`/icon (ghost) inside `_rowChrome` (a `Row` with the existing `ComposePill` as `Expanded` and the "…" pinned trailing). Tapping it calls `item.onMore`.
- In `compose_sections_view.dart`, set `onMore` only for `ContactPillData` / `GroupPillData` / `AdHocGroupPillData` items. The callback opens `CommandModal` with a single command built from the pill data:
  - `ContactPillData(actor)` → `EditContact(contactId: actor.id, name: actor.name ?? '', email: actor.email)`.
  - `GroupPillData(group, members)` → `EditGroup(groupId: group.id, name: group.name, memberContactIds: members.map((a)=>a.id.toUuid()).toList())`.
  - `AdHocGroupPillData(actors, ...)` → `EditGroup(groupId: null, name: '', memberContactIds: actors.map((a)=>a.id.toUuid()).toList())`.
- The page (`new_thread.dart`) provides the `CommandModal`-opening function to `ComposeSectionsView` (a new callback like `onRowMore(ComposePillData)`), keeping `PillGrid`/sections-view free of command knowledge where practical. (If simpler, the sections-view may build the `CommandModal` directly using `rootContext` — choose the cleaner wiring during implementation, following how `onCreateTopic` is threaded.)

## Header ghost buttons

- Add `onAddContact`/`onAddGroup` `Future<bool> Function()?` callbacks to `ComposeSectionsView` (mirroring `onCreateTopic`).
- `_peopleHeader()` becomes a header row with the label + right-aligned ghost buttons "+ Contact" and "+ Group", each shown only when its callback is non-null, styled with `ghostSizedStyleDelta` exactly like `_channelsHeader()`'s "+ Topic". On press → call the callback; on success → reload sections (so a new contact/group surfaces), mirroring `_onCreateTopicPressed`.
- `new_thread.dart` provides the callbacks: `onAddContact` runs `NewContact()`, `onAddGroup` runs `EditGroup()` (blank). Each returns whether a write happened (to trigger reload).

## Keyboard

- Plain **Enter** keeps current behavior (`onActivate` on the highlighted row).
- **Cmd+Enter** on a highlighted eligible row (step-1 picker only) invokes that row's `onMore`. Wire via the existing keyboard path: `PillGrid` already tracks `_highlighted`; route a Cmd+Enter key event (from the page's `_onHardwareKey` or the grid's focus handling) to `_highlighted`'s `onMore` when set. Must not fire in the compose step (where Cmd+Enter = send).

## Edge cases

- **Single contact** is always `ContactPillData` → "Edit contact". Group treatment only for `AdHocGroupPillData` (2+ contacts) or `GroupPillData`.
- **Email-only ad-hoc invitees** (`inviteEmails`, no contact id): not added as group members on create; the `FormShareSelect` still lets the user adjust members. Surface via the form, don't silently drop.
- **`AddContact` empty name**: relax `AddContact` to accept an empty/omitted name (pass `null`/'' to `save_user_contact`'s `p_name`) so email-only contacts can be added. The DB function already accepts a null `p_name`.
- **Just-created group cache gap** (from the prior work): after `CreateGroup` the group isn't in `Group.fromCache` until the next pull. Fine here — the form closes after save; no immediate re-edit.
- **No name change + no member change** on Edit group → no-op (`CommandSkipped` / `CommandDone` without dispatching).

## Testing

- Command unit tests (mock/headless where the form can be bypassed, or test the dispatch logic):
  - `EditGroup` ad-hoc (groupId null) → `CreateGroup` with the prefilled members.
  - `EditGroup` existing (groupId set) with a renamed name + changed members → `RenameGroup` + correct `AddGroupMembers`/`RemoveGroupMembers` deltas.
  - `EditContact` → `RenameContact` with the new name.
  - `NewContact` → `AddContact` with name+email.
  - Where the `FormModal` makes a full command test impractical, factor the dispatch/diff logic into a testable pure function (e.g. `groupMembershipDiff(prev, next)`) and unit-test that.
- `flutter analyze` clean (no new issues).

## Risks / notes

- `FormShareSelect` integration for the members picker is the least-certain piece — confirm its API (`PickShared`) during implementation; if it's heavier than needed, a simpler members display + add/remove may suffice for v1, but the approved design is an editable members picker.
- Threading the row-`onMore` callback vs building `CommandModal` inside the sections-view: pick the wiring that matches how `onCreateTopic` is already threaded, to stay consistent.
- All writes go through the existing offline commands, so the offline/reconciliation behavior (incl. the `members_dirty` intent flag and email-keyed contact reconciliation) is inherited unchanged.
