# Open a role's most-recent focus on desktop — design

**Date:** 2026-06-22
**Status:** Approved design, pending implementation plan
**Scope:** Flutter app (`apps/plot/`). No schema, no sync, no server changes.
**Extends:** the last-open-focus launch feature (PR #411, branch `last-open-focus-spec`). Same feature family, same PR.

## Problem

On desktop, tapping a role header in the left-panel sidebar opens that role's
**first** focus (`childFocuses.first`). The user wants it to open the focus they
most recently opened *within that role* instead — "resume where I was in this
role."

## Current behavior (reference)

`lib/widget/priorities_list.dart:381-398` — the role-header `onTap`:

```dart
onTap: () {
  if (singlePanel) {
    // Single panel: a role tap only discloses (expands) the role's focuses;
    // it never selects/navigates.
    setState(() => _manualExpandedRoleId = role.id);
    return;
  }
  // Left panel (desktop): select the role's first focus.
  if (childFocuses.isNotEmpty) {
    context.run(ChangeCurrentPriority(childFocuses.first));
  }
},
```

- `childFocuses = _focusesForRole(role.id)` (`priorities_list.dart:364,185-187`) —
  the role's **non-archived** focuses, ordered by `_byOrder` (`Priority.order`,
  then `createdAt`; Inbox/FYI pinned to the bottom via sentinel orders). So
  `.first` is the lowest-order (typically oldest non-Inbox) focus.
- This left-panel branch is the **only** place a role-open resolves to a focus.
  The single-panel branch only expands — no focus pick — so the feature is
  inherently desktop-only.

Established facts from the global last-open work already on this branch:

- `lib/state/last_open_focus.dart` holds `kLastOpenFocusKey`,
  `recordLastOpenFocus(Priority?)`, `loadLastOpenFocusId() → PriorityId?` over
  `ProfilePreferences` (device-local `SharedPreferences`). Ids round-trip via
  `Uuid.toString()` ↔ `Uuid.fromString(raw)` + `id.value.validate()` (the
  validate guards against a corrupt pref).
- Recording happens once, in `ChangeCurrentPriority.run()`
  (`lib/command/priority.dart:165-169`): `unawaited(recordLastOpenFocus(priority));`.
  `ChangeCurrentPriority` is the single command every deliberate focus pick
  funnels through.
- `RoleId = Uuid`; `Priority.roleId` is `RoleId?` (nullable — role-less /
  pre-role-model focuses). `Role` does not know its focuses; you filter
  `Priority.roleId == role.id`.

## Decisions (from brainstorming)

1. **"Most recent" = most recently deliberately picked focus in that role** —
   same trigger and semantics as the global last-open (`ChangeCurrentPriority`).
2. **The Inbox counts.** If the last focus you picked in a role was its Inbox,
   opening the role reopens the Inbox. Consistent with the global feature, which
   already remembers deliberate Inbox picks.
3. **Fallback to today's behavior** (`childFocuses.first`) when nothing is
   remembered for the role, or the remembered focus is gone from the role's
   current list (archived / deleted / moved to another role).
4. **Desktop left-panel only.** Single-panel role tap is unchanged.
5. **Device-local, not synced.** Per-role, mirroring the global feature.

## Design

### Record (per role, alongside the global)

In `lib/state/last_open_focus.dart`:

- Add `Future<void> recordLastOpenFocusForRole(Priority? picked)`:
  - No-op when `picked == null` (the "Everything" feed).
  - No-op when `picked.roleId == null` (role-less focuses have no per-role slot).
  - Otherwise write `ProfilePreferences` key `last_open_focus_role_<roleId>` =
    `picked.id.toString()`, where `<roleId>` is `roleId.toString()` (canonical
    UUID). Helper: `String _roleKey(RoleId roleId) => 'last_open_focus_role_$roleId';`.

In `lib/command/priority.dart`, `ChangeCurrentPriority.run()` — add immediately
after the existing global record:

```dart
unawaited(recordLastOpenFocus(priority));
unawaited(recordLastOpenFocusForRole(priority)); // NEW
```

So one deliberate pick updates both the global last-open and its role's
last-open. (A deliberate Inbox pick has a `roleId`, so it is recorded per
decision 2.)

### Resolve (at the role-tap site)

In `lib/state/last_open_focus.dart`:

- Refactor the id-parsing into one private helper and reuse it in both loaders
  (DRY cleanup — existing behavior unchanged):

  ```dart
  PriorityId? _parseStoredFocusId(String? raw) {
    if (raw == null) return null;
    try {
      final id = Uuid.fromString(raw);
      id.value.validate();
      return id;
    } catch (_) {
      return null;
    }
  }
  ```

  `loadLastOpenFocusId()` becomes `try { return _parseStoredFocusId(
  ProfilePreferences.instance.getString(kLastOpenFocusKey)); } catch (_) { return null; }`.

- Add `PriorityId? loadLastOpenFocusIdForRole(RoleId roleId)` — same shape,
  reading `_roleKey(roleId)`; defensive null on missing/malformed/uninitialized.

- Add a **pure** selector:

  ```dart
  /// The focus to open when [roleFocuses] (a role's current, ordered,
  /// non-archived focuses — must be non-empty) is opened: the remembered
  /// [rememberedId] if it's still present, else the first. A null/absent/
  /// since-removed id falls through to the first.
  Priority pickRoleOpenFocus(List<Priority> roleFocuses, PriorityId? rememberedId) =>
      roleFocuses.firstWhere((f) => f.id == rememberedId,
          orElse: () => roleFocuses.first);
  ```

  Robust by construction: the caller passes the role's current non-archived
  focus list, so an archived / moved / unknown remembered id simply isn't found
  and resolves to `.first`.

In `lib/widget/priorities_list.dart` (the left-panel branch, ~397):

```dart
if (childFocuses.isNotEmpty) {
  final remembered = loadLastOpenFocusIdForRole(role.id);
  context.run(ChangeCurrentPriority(pickRoleOpenFocus(childFocuses, remembered)));
}
```

The existing `childFocuses.isNotEmpty` guard stays (so `pickRoleOpenFocus`'s
non-empty precondition holds). `loadLastOpenFocusIdForRole` is a plain function
over `ProfilePreferences` (not Bloc state), so the widget stays thin and
convention-compliant.

### Why this shape

- **Reuses the global feature's funnel and storage** — one recording site
  (`ChangeCurrentPriority`), the same `ProfilePreferences`/`Uuid` machinery, the
  same defensive parse. No new persistence concept.
- **Pure selector** isolates the only real logic for fast, exhaustive unit
  tests; the loaders are thin pref wrappers; the widget is declarative.

## Testing

Flutter-only.

- **`pickRoleOpenFocus` (pure):** remembered present → returns it; remembered
  null → first; remembered absent (archived/moved/unknown) → first; single-focus
  list → that focus.
- **Per-role record/load round-trip** (mocked `SharedPreferences` +
  `ProfilePreferences.init`): record a focus in a role → `loadLastOpenFocusIdForRole`
  returns its id; `recordLastOpenFocusForRole(null)` and a role-less focus write
  nothing; load returns null when absent; load returns null when the stored
  value is malformed.
- **Existing `loadLastOpenFocusId` tests still pass** after the parse refactor
  (behavior unchanged).
- **Recording funnel + widget wiring:** `flutter analyze` clean (the logic lives
  in the unit-tested helpers); end-to-end confirmed in the manual run-app check.

## Out of scope

- Changing single-panel/mobile role-tap behavior.
- Any cross-device sync of per-role recency.
- A general focus-recency/MRU history (only the single most-recent focus per
  role is stored).
- Schema / server / connector changes.
