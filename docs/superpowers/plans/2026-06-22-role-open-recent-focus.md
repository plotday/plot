# Open a Role's Most-Recent Focus (Desktop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On desktop, tapping a role header opens the focus you most recently picked within that role, instead of always its first focus.

**Architecture:** Extend the existing device-local last-open-focus module with a per-role slot (`last_open_focus_role_<roleId>`), recorded on the same `ChangeCurrentPriority` funnel as the global last-open. A pure selector resolves a role's remembered focus against its current focus list, falling back to `.first`. The desktop role-tap site (`priorities_list.dart`) uses it.

**Tech Stack:** Flutter, flutter_bloc, `shared_preferences` via `ProfilePreferences`, `flutter_test`. **No database/Drift schema change.**

**Design spec:** `docs/superpowers/specs/2026-06-22-role-open-recent-focus-design.md`

## Global Constraints

- **No Drift/database schema change.** Device-local pref + pure logic only.
- **Device-local, not synced.** Per-role key `last_open_focus_role_<roleId>` in `ProfilePreferences`, where `<roleId>` is `roleId.toString()` (canonical UUID).
- **Recording trigger is deliberate picks only** — extend the existing single record site in `ChangeCurrentPriority.run()`. Do not record from automatic `setContext` callers.
- **The Inbox counts** as a role's most-recent focus (a deliberate Inbox pick has a `roleId`, so it is recorded).
- **No-op recording** when the picked priority is null ("Everything" feed) or has a null `roleId` (role-less / pre-role-model focuses).
- **Fallback** to today's behavior (`childFocuses.first`) when nothing is remembered for the role or the remembered focus is no longer in the role's current non-archived list.
- **Desktop / left-panel only.** Do not change the single-panel role-tap branch (it only expands).
- App code imports only `flutter/widgets.dart` / `forui/forui.dart`, never `flutter/material.dart`.
- `flutter analyze` must be clean before each commit (`cd apps/plot && flutter analyze`).
- This worktree was created without git hooks (husky broken) — commit with `git commit --no-verify`.

---

## Setup (already done — confirm only)

This worktree (`last-open-focus-spec`) already has Flutter deps + generated Drift code from the prior last-open-focus feature. There is **no schema change** here, so no `build_runner` run is needed. Confirm the baseline before Task 1:

- [ ] **S1: Confirm baseline**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: PASS (the existing last-open-focus tests — the file you will extend). If it fails to compile due to missing generated code, run `dart run build_runner build --delete-conflicting-outputs` once, then retry.

---

## Task 1: Per-role persistence + pure role-open selector

Extend `lib/state/last_open_focus.dart` with a per-role write/read and a pure selector, and DRY the id-parsing into one shared helper. All independently unit-testable.

**Files:**
- Modify: `apps/plot/lib/state/last_open_focus.dart`
- Test: `apps/plot/test/state/last_open_focus_test.dart` (extend — keep existing groups intact)

**Interfaces:**
- Consumes: `ProfilePreferences`, `Priority`/`PriorityId`/`RoleId`/`Uuid` (all from `package:plot/store/store.dart`, already imported in the module).
- Produces:
  - `Future<void> recordLastOpenFocusForRole(Priority? picked)` — writes `last_open_focus_role_<roleId>`; no-op on null picked or null `roleId`.
  - `PriorityId? loadLastOpenFocusIdForRole(RoleId roleId)` — defensive null on missing/malformed/uninitialized.
  - `Priority pickRoleOpenFocus(List<Priority> roleFocuses, PriorityId? rememberedId)` — pure; requires non-empty list; returns remembered focus if present, else first.
  - (refactor) private `PriorityId? _parseStoredFocusId(String? raw)` shared by both loaders; `loadLastOpenFocusId()` behavior unchanged.

- [ ] **Step 1: Write the failing tests**

In `apps/plot/test/state/last_open_focus_test.dart`:

First, extend the shared `_focus` helper to accept a `roleId` (it currently doesn't set one). Change its signature and add the `roleId` field to the `PriorityRow`:

```dart
Priority _focus(String title, {bool isInbox = false, RoleId? roleId}) =>
    Priority.fromStore(
      PriorityRow(
        id: Uuid.generate(),
        createdBy: Uuid.generate(),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        title: title,
        path: Path(title.toLowerCase()),
        order: const Order(0),
        unread: false,
        role: 'member',
        roleId: roleId,
        isInbox: isInbox,
        isFyi: false,
        attentionWindowSet: false,
        seeWithinSet: false,
        earlyNotificationsEnabledSet: false,
        notifyWindowSet: false,
      ),
      draft: true,
    );
```

(`role: 'member'` is the membership string and is unrelated to `roleId` — keep it. `roleId` is an optional named param defaulting null, so every existing `_focus('X')` call is unaffected.)

Then add two new groups inside `main()` (after the existing groups, before the closing `}`):

```dart
  group('pickRoleOpenFocus', () {
    test('returns the remembered focus when it is present', () {
      final a = _focus('A');
      final b = _focus('B');
      final c = _focus('C');
      expect(pickRoleOpenFocus([a, b, c], b.id).id, b.id);
    });

    test('returns the first focus when nothing is remembered', () {
      final a = _focus('A');
      final b = _focus('B');
      expect(pickRoleOpenFocus([a, b], null).id, a.id);
    });

    test('returns the first when the remembered focus is no longer in the role', () {
      final a = _focus('A');
      final b = _focus('B');
      expect(pickRoleOpenFocus([a, b], Uuid.generate()).id, a.id);
    });

    test('returns the only focus in a single-focus role', () {
      final a = _focus('A');
      expect(pickRoleOpenFocus([a], a.id).id, a.id);
    });
  });

  group('recordLastOpenFocusForRole / loadLastOpenFocusIdForRole', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('record then load round-trips the focus id for its role', () async {
      final role = Uuid.generate();
      final work = _focus('Work', roleId: role);
      await recordLastOpenFocusForRole(work);
      expect(loadLastOpenFocusIdForRole(role), work.id);
    });

    test('per-role slots are independent', () async {
      final roleA = Uuid.generate();
      final roleB = Uuid.generate();
      final a = _focus('A', roleId: roleA);
      final b = _focus('B', roleId: roleB);
      await recordLastOpenFocusForRole(a);
      await recordLastOpenFocusForRole(b);
      expect(loadLastOpenFocusIdForRole(roleA), a.id);
      expect(loadLastOpenFocusIdForRole(roleB), b.id);
    });

    test('records nothing for the Everything feed (null picked)', () async {
      final role = Uuid.generate();
      await recordLastOpenFocusForRole(null);
      expect(loadLastOpenFocusIdForRole(role), isNull);
    });

    test('records nothing for a role-less focus (no roleId)', () async {
      final roleless = _focus('Roleless'); // roleId == null
      await recordLastOpenFocusForRole(roleless); // must not throw
      // Nothing was keyed; an arbitrary role still reads null.
      expect(loadLastOpenFocusIdForRole(Uuid.generate()), isNull);
    });

    test('load returns null for a role with nothing recorded', () {
      expect(loadLastOpenFocusIdForRole(Uuid.generate()), isNull);
    });

    test('load returns null when the stored value is malformed', () async {
      final role = Uuid.generate();
      await ProfilePreferences.instance
          .setString('last_open_focus_role_$role', 'not-a-uuid');
      expect(loadLastOpenFocusIdForRole(role), isNull);
    });
  });
```

- [ ] **Step 2: Run the new groups to verify they fail**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart --plain-name 'Role'
```

Expected: FAIL to compile — `pickRoleOpenFocus`, `recordLastOpenFocusForRole`, `loadLastOpenFocusIdForRole` are undefined (and `_focus` has no `roleId` param until you add it in Step 1).

- [ ] **Step 3: Implement in `last_open_focus.dart`**

Replace the body of `apps/plot/lib/state/last_open_focus.dart` (after the imports and `kLastOpenFocusKey`) so it reads:

```dart
const String kLastOpenFocusKey = 'last_open_focus';

/// Device-local SharedPreferences key for the focus the user most recently
/// *deliberately chose* within [roleId]. Written alongside [kLastOpenFocusKey]
/// by `ChangeCurrentPriority`; read when a role is opened on desktop so it
/// reopens that role's most-recent focus. Not synced.
String _roleKey(RoleId roleId) => 'last_open_focus_role_$roleId';

/// Persist [picked] as the device-local "last open focus".
///
/// No-op when [picked] is null: the only null caller is the synthetic
/// "Everything" feed (`ChangeCurrentPriority.everything`), which has no anchor
/// focus and must leave the previously stored real focus intact.
Future<void> recordLastOpenFocus(Priority? picked) async {
  if (picked == null) return;
  await ProfilePreferences.instance
      .setString(kLastOpenFocusKey, picked.id.toString());
}

/// Persist [picked] as the device-local "last open focus" for its role.
///
/// No-op when [picked] is null (the "Everything" feed) or [picked] has no
/// [Priority.roleId] (role-less / pre-role-model focuses have no per-role slot).
Future<void> recordLastOpenFocusForRole(Priority? picked) async {
  if (picked == null) return;
  final roleId = picked.roleId;
  if (roleId == null) return;
  await ProfilePreferences.instance
      .setString(_roleKey(roleId), picked.id.toString());
}

/// Parse a stored focus id, or null when [raw] is null or not a valid UUID.
PriorityId? _parseStoredFocusId(String? raw) {
  if (raw == null) return null;
  try {
    final id = Uuid.fromString(raw);
    // UuidValue.fromString() accepts any string without validation; validate()
    // makes malformed values throw and fall through to null.
    id.value.validate();
    return id;
  } catch (_) {
    return null;
  }
}

/// Read the device-local "last open focus" id, or null when unset, the stored
/// value can't be parsed (corrupt pref), or prefs aren't initialized yet.
PriorityId? loadLastOpenFocusId() {
  try {
    return _parseStoredFocusId(
        ProfilePreferences.instance.getString(kLastOpenFocusKey));
  } catch (_) {
    // ProfilePreferences not initialized (some non-production paths).
    return null;
  }
}

/// Read the device-local "last open focus" id for [roleId], or null when unset,
/// unparseable, or prefs aren't initialized.
PriorityId? loadLastOpenFocusIdForRole(RoleId roleId) {
  try {
    return _parseStoredFocusId(
        ProfilePreferences.instance.getString(_roleKey(roleId)));
  } catch (_) {
    return null;
  }
}

/// The focus to open when [roleFocuses] — a role's current, ordered,
/// non-archived focuses (must be non-empty) — is opened: the remembered
/// [rememberedId] if it's still present in the list, else the first. A null,
/// absent, or since-removed (archived/moved) id falls through to the first.
Priority pickRoleOpenFocus(List<Priority> roleFocuses, PriorityId? rememberedId) =>
    roleFocuses.firstWhere((f) => f.id == rememberedId,
        orElse: () => roleFocuses.first);
```

(The imports at the top — `package:plot/store/store.dart` and `package:plot/util/profile_preferences.dart` — are unchanged and already present. `RoleId` comes from `store.dart`.)

- [ ] **Step 4: Run the full test file to verify it passes**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: PASS — all groups (the existing last-open-focus groups + the two new `pickRoleOpenFocus` and per-role groups; the existing `loadLastOpenFocusId` tests still pass after the `_parseStoredFocusId` refactor).

- [ ] **Step 5: Analyze**

```bash
cd apps/plot && flutter analyze lib/state/last_open_focus.dart test/state/last_open_focus_test.dart
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/last_open_focus.dart apps/plot/test/state/last_open_focus_test.dart
git commit --no-verify -m "feat(app): per-role last-open focus persistence + selector"
```

---

## Task 2: Wire per-role record + resolve into the app

Record the per-role slot on every deliberate pick, and use it when a role is opened on desktop.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (`ChangeCurrentPriority.run()`, ~165-169)
- Modify: `apps/plot/lib/widget/priorities_list.dart` (imports; the left-panel role-tap branch, ~391-398)

**Interfaces:**
- Consumes: `recordLastOpenFocusForRole`, `loadLastOpenFocusIdForRole`, `pickRoleOpenFocus` (Task 1).
- Produces: nothing new — wiring.

No new unit test: the helpers are unit-tested in Task 1; the command path needs a full router context and the widget tap needs a full UI context (out of scope for unit tests). Verified by `flutter analyze` here and the manual run-app check in Task 3.

- [ ] **Step 1: Record per-role alongside the global record**

In `apps/plot/lib/command/priority.dart`, `ChangeCurrentPriority.run()`, the existing block is:

```dart
    // Remember this deliberate pick as the device-local "last open focus" so
    // the next cold start reopens here instead of the Inbox. Null for the
    // synthetic "Everything" feed (the helper no-ops). Fire-and-forget — a
    // missed pref write is harmless and must not delay navigation.
    unawaited(recordLastOpenFocus(priority));
```

Add the per-role record immediately after it:

```dart
    unawaited(recordLastOpenFocus(priority));
    // Also remember it as this role's most-recent focus, so opening the role on
    // desktop reopens here. No-op for the "Everything" feed and role-less
    // focuses (the helper guards both).
    unawaited(recordLastOpenFocusForRole(priority));
```

(`recordLastOpenFocusForRole` is exported from `package:plot/state/last_open_focus.dart`, which `priority.dart` already imports. `unawaited` is already in scope via `import 'dart:async';`.)

- [ ] **Step 2: Resolve at the desktop role-tap site**

In `apps/plot/lib/widget/priorities_list.dart`, add the import with the other `package:plot/...` imports (after `import 'package:plot/command/command.dart';`):

```dart
import 'package:plot/state/last_open_focus.dart';
```

Then change the left-panel branch of the role-header `onTap` (currently):

```dart
                    // Left panel: selecting the role's first focus expands it and
                    // shows its feed alongside the still-visible sidebar. Roles
                    // always have at least their Inbox, so the list is non-empty
                    // in practice; guard anyway.
                    if (childFocuses.isNotEmpty) {
                      context.run(ChangeCurrentPriority(childFocuses.first));
                    }
```

to:

```dart
                    // Left panel: open the role's most-recently-opened focus
                    // (falling back to its first) and show its feed alongside
                    // the still-visible sidebar. `childFocuses` is already this
                    // role's ordered, non-archived focuses, so a since-removed
                    // remembered focus falls through to the first. Roles always
                    // have at least their Inbox, so the list is non-empty in
                    // practice; guard anyway.
                    if (childFocuses.isNotEmpty) {
                      final remembered = loadLastOpenFocusIdForRole(role.id);
                      context.run(ChangeCurrentPriority(
                          pickRoleOpenFocus(childFocuses, remembered)));
                    }
```

- [ ] **Step 3: Analyze**

```bash
cd apps/plot && flutter analyze lib/command/priority.dart lib/widget/priorities_list.dart
```

Expected: clean.

- [ ] **Step 4: Regression test (the funnel's unit coverage still green)**

```bash
cd apps/plot && flutter test test/state/last_open_focus_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/priority.dart apps/plot/lib/widget/priorities_list.dart
git commit --no-verify -m "feat(app): open a role's most-recent focus on desktop"
```

---

## Task 3: Docs, full analyze, and end-to-end verification

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, under the existing `### Opening the app` section in `## Next release` (it already contains the global last-open bullet), add a second bullet:

```markdown
- Opening a role now reopens the focus you last had open in that role, instead of always its first.
```

- [ ] **Step 2: Full analyze**

```bash
cd apps/plot && flutter analyze
```

Expected: "No issues found!" (or only pre-existing unrelated issues).

- [ ] **Step 3: Full state test run**

```bash
cd apps/plot && flutter test test/state/
```

Expected: PASS (no regressions; includes the new per-role tests).

- [ ] **Step 4: Manual end-to-end verification (desktop / multi-panel)**

Use the `run-app` skill to launch the macOS app in a desktop window, then verify (record the observed result for each):

1. **Per-role reopen:** In role R, open a non-first focus (e.g. its 2nd or 3rd focus). Open a different role, then tap role R's header again. → It opens the focus you last had open in R, not R's first.
2. **Inbox counts:** In role R, open R's Inbox. Switch away, then tap R's header. → It opens R's Inbox.
3. **Fallback (fresh role):** Tap the header of a role you've never opened a focus in this session/device. → It opens that role's first focus (today's behavior).
4. **Archived fallback:** Open a focus in role R, archive it, then tap R's header. → It opens R's first focus (graceful fallback).
5. **Independence:** Set role A → focus A2 and role B → focus B3; tapping A opens A2, tapping B opens B3.

If any case fails, stop and debug before proceeding.

- [ ] **Step 5: Commit docs**

```bash
git add docs/updates.md
git commit --no-verify -m "docs: note role-open most-recent focus in updates"
```

---

## Self-Review (completed during plan authoring)

- **Spec coverage:** per-role record (`recordLastOpenFocusForRole`, Task 1 + wired Task 2), per-role load (`loadLastOpenFocusIdForRole`, Task 1), pure selector with fallback (`pickRoleOpenFocus`, Task 1), parse-helper DRY refactor (Task 1), desktop role-tap resolution (Task 2), Inbox-counts + role-less/null no-op (Task 1 tests + Task 2 wiring), key format `last_open_focus_role_<roleId>` (Task 1), desktop-only/no-schema/not-synced constraints stated, docs (Task 3). Single-panel left untouched (Task 2 changes only the left-panel branch).
- **Placeholder scan:** none — every code/test step shows complete code.
- **Type consistency:** `recordLastOpenFocusForRole(Priority?)`, `loadLastOpenFocusIdForRole(RoleId) → PriorityId?`, `pickRoleOpenFocus(List<Priority>, PriorityId?) → Priority`, `_roleKey(RoleId) → String`, `_parseStoredFocusId(String?) → PriorityId?` — names/types consistent across Tasks 1-2.
