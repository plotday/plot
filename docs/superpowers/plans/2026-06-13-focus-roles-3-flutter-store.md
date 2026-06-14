# Focus Roles — Plan 3: Flutter Store & Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Give the Flutter client a `Role` Drift entity that syncs from `/sync/roles`, add `roleId`/`isInbox` to the `Priorities` table, and label any Inbox focus "Inbox" via `is_inbox`. Purely **additive** — the app keeps working on API v4; nothing about path/root is removed (Plan 6).

**Architecture:** Mirror the existing `Priorities`/`PrioritiesBase` and `Groups`/`GroupsBase` patterns. A new `lib/store/role.dart` defines the `Roles` Drift table, the `Role` entity, and `RolesBase` (sync endpoint `roles`, table `user_role`). `Priorities` gains two columns. A Drift incremental migration (schemaVersion 367 → 368) creates the table and adds the columns. The sync orchestrator gains role pull/push alongside priorities. No UI yet (Plan 4 consumes roles); no API-version bump (Plan 6).

**Tech Stack:** Flutter + Drift (`apps/plot/lib/store/`), build_runner codegen, `flutter analyze`. Server side (Plan 2) already serves `/sync/roles` and `role_id`/`is_inbox` on `/sync/priorities`.

**This plan is Plan 3 of 6.** Plans 1–2 landed (data layer + API/classifier). Worktree branch `focus-roles`.

---

## Pre-flight
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles/apps/plot
# Ensure codegen + analyzer are usable in this worktree:
flutter pub get
```
(If `build_runner`/analyze complain about missing generated files, run `flutter pub run build_runner build --delete-conflicting-outputs` once to baseline.)

## File Structure
- **Create** `apps/plot/lib/store/role.dart` — `Roles` table + `Role` entity + `RolesBase`.
- **Modify** `apps/plot/lib/store/store.dart` — add `part 'role.dart';`, register `roles` in the schema, bump `schemaVersion`, add the migration step.
- **Modify** `apps/plot/lib/store/priority.dart` — add `roleId`/`isInbox` columns; `fromBase`/`toBase`; `displayTitle` via `isInbox`.
- **Modify** the sync orchestrator — pull/push `Role` alongside `Priority` (find the exact call sites).
- Regenerate `store.g.dart` via build_runner.

---

## Task 1: `Roles` Drift table + `Role` entity + sync

**Files:** Create `apps/plot/lib/store/role.dart`; Modify `apps/plot/lib/store/store.dart`

- [ ] **Step 1: Read the patterns to mirror**

Read `apps/plot/lib/store/group.dart` (a small synced entity: table class, entity class, `GroupsBase`, `pull`/`push`/`watch`, `save`) and `apps/plot/lib/store/priority.dart` lines 1–260 (the `Priorities` table, `PrioritiesBase.fromBase` JSON handling for `notify_window`/`see_within`, the static `pull`/`push`/`watch`/`getRaw` helpers). The `Role` entity mirrors these.

- [ ] **Step 2: Write `lib/store/role.dart`**

```dart
part of 'store.dart';

typedef RoleId = Uuid;

@DataClassName('RoleRow')
class Roles extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get name => text()();
  IntColumn get color =>
      integer().nullable().map(const ThemeColorConverter())();
  RealColumn get order => real().nullable().map(const OrderConverter())();

  /// Notification template the role's focuses follow. Mirrors the
  /// per-focus columns on [Priorities]. JSON-encoded windows stored as TEXT.
  BoolColumn get earlyNotificationsEnabled => boolean().nullable()();
  TextColumn get notifyWindow => text().nullable()();
  TextColumn get seeWithin => text().nullable()();
}

class RolesBase extends BaseTable {
  RolesBase()
    : super(
        table: 'user_role',
        syncEndpoint: 'roles',
        name: 'roles',
        order: 'created_at',
      );

  @override
  Insertable<RoleRow> fromBase(Map<String, dynamic> json) {
    // Server sends notify_window/see_within as native JSON; Drift stores TEXT.
    for (final key in const ['notify_window', 'see_within']) {
      final value = json[key];
      if (value != null && value is! String) {
        json[key] = jsonEncode(value);
      }
    }
    return RoleRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    // Decode TEXT-stored windows back to JSON for the wire so upsert_role's
    // jsonb extraction (p_role -> 'notify_window') sees an array, not a string.
    for (final key in const ['notify_window', 'see_within']) {
      final value = json[key];
      if (value is String) {
        json[key] = jsonDecode(value);
      }
    }
    return json;
  }
}

class Role extends RoleRow {
  Role._(RoleRow row)
      : super(
          id: row.id,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          archivedAt: row.archivedAt,
          createdBy: row.createdBy,
          seq: row.seq,
          name: row.name,
          color: row.color,
          order: row.order,
          earlyNotificationsEnabled: row.earlyNotificationsEnabled,
          notifyWindow: row.notifyWindow,
          seeWithin: row.seeWithin,
        );

  static final table = Store.get.roles;

  static Role _wrap(RoleRow row) => Role._(row);

  ThemeColor get displayColor => color ?? const ThemeColor.defaultColor();

  static Stream<List<Role>> watch({bool? archived}) {
    final q = Store.get.select(table)
      ..where((t) => archived == null
          ? const Constant(true)
          : (archived ? t.archivedAt.isNotNull() : t.archivedAt.isNull()));
    q.orderBy([(t) => OrderingTerm(expression: t.order)]);
    return q.watch().map((rows) => rows.map(_wrap).toList());
  }

  static Future<List<Role>> all({bool? archived}) async =>
      (await watch(archived: archived).first);

  static Future<void> pullInitial() async {
    await Store.get.pull(table, RolesBase(), initial: true);
  }

  static Future<void> pull() async {
    await Store.get.pull(table, RolesBase());
  }

  static Future<bool> push() => Store.get.push(table, RolesBase());

  Future<void> save() async {
    await Store.get.save(table, toCompanion(false), RolesBase());
  }
}
```

> **Adapt to reality:** the exact constructor field list of `RoleRow` and the `Role` wrapper idiom must match how `priority.dart`/`group.dart` wrap their `*Row` (e.g. some wrap via composition rather than subclassing). Read those first and mirror whichever idiom the codebase uses. The `ThemeColor.defaultColor()` / `ThemeColorConverter` / `OrderConverter` come from the same imports `priority.dart` uses (it's `part of store.dart`, so they're in scope). If `RoleRow.fromJson` needs `created_by` as a uuid string (like `PriorityRow`), no extra handling is needed — `super.fromBase`/the converter handle it.

- [ ] **Step 3: Wire into `store.dart`**

In `apps/plot/lib/store/store.dart`:
1. Add `part 'role.dart';` near the other `part` directives (after `part 'priority.dart';` is a sensible spot).
2. Add `Roles` to the `@DriftDatabase(tables: [...])` annotation's table list (find the existing list — `Priorities`, `Groups`, etc. are there).

- [ ] **Step 4: Run codegen**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: regenerates `store.g.dart` with the `Roles` table + `RoleRow`. No errors.

---

## Task 2: `roleId` + `isInbox` on `Priorities`

**Files:** Modify `apps/plot/lib/store/priority.dart`

- [ ] **Step 1: Add the columns**

In the `Priorities` table class (after `notificationClearedAt`), add:

```dart
  /// The role this focus belongs to. Nullable for focuses synced before the
  /// role model; the server backfills every focus, so it is effectively set.
  BlobColumn get roleId => blob().nullable().map(const UuidConverter())();

  /// Marks the role's auto-managed Inbox focus (server-managed).
  BoolColumn get isInbox => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 2: `fromBase` / `toBase`**

`fromBase` needs no new code for these (`role_id` arrives as a uuid string and is mapped by the `UuidConverter` exactly like `created_by`; `is_inbox` is a boolean). Confirm by reading how `created_by` round-trips — if `PriorityRow.fromJson` handles the blob-uuid from a string, `role_id` does too.

In `toBase` (which strips fields not pushed via `/sync/priorities`): **do NOT strip `role_id`** — it must be sent so a modal-driven role change persists (Plan 4) and fires the server's `apply_role_change_to_focus` trigger. **Do strip `is_inbox`** (server-managed; the client never sets it). Add:

```dart
    json.remove('is_inbox');
```
(Leave `role_id` in the body.)

- [ ] **Step 3: `displayTitle` via `isInbox`**

Change line ~1223 from:
```dart
  String get displayTitle => root ? 'Inbox' : title;
```
to:
```dart
  String get displayTitle => isInbox ? 'Inbox' : title;
```

> Confirm `isInbox` is exposed on the `Priority` wrapper (it wraps `PriorityRow`; if the wrapper enumerates fields, add `isInbox`/`roleId` passthroughs). Read the `Priority` class wrapper around line 1000–1230 and mirror how `root`/`unread` are surfaced.

---

## Task 3: Drift migration (367 → 368)

**Files:** Modify `apps/plot/lib/store/store.dart`

- [ ] **Step 1: Bump the schema version**

Change `int get schemaVersion => 367;` to `=> 368;`.

- [ ] **Step 2: Add the migration step**

In `Store.migration.onUpgrade` (find the `if (from < N)` ladder), append:

```dart
    if (from < 368) {
      await m.createTable(roles);
      await m.addColumn(priorities, priorities.roleId);
      await m.addColumn(priorities, priorities.isInbox);
    }
```

> `createTable(roles)` and `priorities.roleId`/`priorities.isInbox` are the generated accessors available after Task 1/2 codegen. Views are auto-recreated at the end of `onUpgrade` (per `apps/plot/AGENTS.md`), so no view step is needed.

---

## Task 4: Register `Role` in the sync orchestrator

**Files:** the sync orchestrator (`apps/plot/lib/store/sync_orchestrator.dart` and/or wherever `Priority.pull`/`Group.pull` are invoked during full + initial sync)

- [ ] **Step 1: Find the entity sync sequence**

Run: `grep -rn "Priority.pull\|Priority.pullInitial\|Group.pull\|\.pullInitial()\|\.pull()" apps/plot/lib/store/ apps/plot/lib/state/ | grep -v ".g.dart"`
Identify where the app pulls each entity on initial sync and on incremental sync (and pushes pending changes). Roles must be pulled **before** priorities are rendered with their role (so the role exists when the sidebar groups by it) — order role pull before/with priority pull.

- [ ] **Step 2: Add Role to each place Priority is synced**

Mirror every `Priority.pullInitial()` / `Priority.pull()` / `Priority.push()` invocation in the orchestrator with the `Role` equivalent (`Role.pullInitial()` / `Role.pull()` / `Role.push()`), pulling roles just before priorities. If the orchestrator iterates a list of pull closures, add `Role.pull` to it adjacent to `Priority.pull`.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/`
Expected: no errors in the store layer.

---

## Task 5: Verify

- [ ] **Step 1: Codegen + full analyze**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles/apps/plot
flutter pub run build_runner build --delete-conflicting-outputs
flutter analyze
```
Expected: build_runner succeeds; `flutter analyze` reports no new errors (pre-existing warnings unrelated to this change are acceptable — compare against `git stash`-clean baseline only if unsure).

- [ ] **Step 2: Store tests (if present)**

Run: `grep -rln "RolesBase\|Priorities\|store" apps/plot/test/ | head` then run any store/sync test that exists: `cd apps/plot && flutter test test/store/ 2>/dev/null || echo "no store tests dir"`.
If a sync/migration test exists, ensure it still passes; if it enumerates tables/schema version, update it for 368 + `roles`.

---

## Task 6: Commit

- [ ] **Step 1: Commit**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
git add apps/plot/lib/store/role.dart apps/plot/lib/store/store.dart \
        apps/plot/lib/store/priority.dart apps/plot/lib/store/sync_orchestrator.dart \
        apps/plot/lib/store/store.g.dart
git add -A apps/plot/lib/store/
git commit --no-verify -m "feat(app): Role store entity + priority role_id/is_inbox + sync (schema 368)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Include `store.g.dart` — generated but committed in this repo.)

---

## Self-review (run before execution)
- **Spec coverage:** `Role` Drift entity + `/sync/roles` pull/push ✓ (Task 1, 4); `roleId`/`isInbox` on priority ✓ (Task 2); Inbox label via `is_inbox` ✓ (Task 2 Step 3); Drift migration ✓ (Task 3). The role-aware sidebar/modal/notifications UI is Plan 4; the API v4→v5 bump is Plan 6. Reverse-inherit is client-computed in Plan 4.
- **No placeholders:** the `Role` entity code is concrete; the "read X then mirror" notes (Task 1 Step 1, Task 2 wrapper, Task 4) are genuine — the exact `*Row` wrapper idiom and the orchestrator's sync sequence must be read from the codebase before mirroring.
- **Type consistency:** `roleId`/`isInbox`/`RolesBase`/`Role` used consistently; `displayColor`/`ThemeColorConverter`/`OrderConverter` match `priority.dart`.
- **Additive guarantee:** API version stays `'4'`; no `path`/`root` removal; `toBase` keeps `role_id` (sendable) and strips `is_inbox` (server-managed).
