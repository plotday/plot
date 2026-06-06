# Groups & Topics — Plan 4: Client Store

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the Flutter (Drift) client-store support for topics & group privacy: a read-only `TopicRow` store synced from `/sync/topics`, plus `GroupRow.privacy`/`canAddress` and `ThreadRow.topicId` columns. Non-UI: tables + sync wiring only (compose/picker UI is a later effort).

**Architecture:** Mirror the existing `group.dart` store (Drift `Table` with `SyncableTable`/`UuidTable`/`DeletableTable`, a `BaseTable` with `syncEndpoint`, a static helper class with `pull`/cache, and a read-only `SyncEntity` in `sync_orchestrator.dart`). Schema changes go through an incremental Drift migration (`if (from < 356)`), `schemaVersion` bump, and `build_runner` codegen.

**Tech Stack:** Flutter/Dart, Drift (SQLite), `flutter analyze`. The worktree must be Flutter-bootstrapped (`flutter pub get` + `dart run build_runner build` + `app.env` — already done for this session).

**Design doc:** `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`. **Plan 4 of 5**; Plans 1–3 (DB + API) are committed/pushed on this branch. The Flutter client sends `X-Plot-API-Version: 4` (`lib/api/api.dart:218`), so `/sync/topics` returns the new `user.topic` entity (not the legacy group-compat).

## Grounded references
- Store to mirror: `apps/plot/lib/store/group.dart` (table `Groups`→`GroupRow`, `GroupsBase(table:'user_group', syncEndpoint:'groups')`, `Group` helper class). Part files declared in `apps/plot/lib/store/store.dart` (`part 'group.dart';` at ~line 86).
- Sync registration: `apps/plot/lib/store/sync_orchestrator.dart` — `SyncEntity(debugName, dependsOn:[], pushFn: () async => true, pullFn: X.pull)` (group at ~line 52), collected in `static final allEntities = [ … ]` (~line 149, `group` at 151), and a name→entity switch at ~line 242 (`'user_group' || 'group' || 'user_topic' || 'topic' => group`).
- Migration: `apps/plot/lib/store/store.dart` — `onUpgrade` with `if (from < N)` blocks (latest `from < 355`); `int get schemaVersion => 355;` (~line 2411). Add-column: `await m.addColumn(table, table.col);`; add-table: `await m.createTable(table);`.
- Thread store: `apps/plot/lib/store/thread.dart` — `Threads`→`ThreadRow` (~line 35), nullable-uuid column pattern `blob().nullable().map(const UuidConverter())()` (e.g. `mergedIntoThreadId` ~line 135); `Thread._fromStore({required ThreadRow activity, …})` wraps the whole row as `_thread`, with accessors like `topic => _thread.topic` (~line 4854) and `mergedIntoThreadId => _thread.mergedIntoThreadId` (~line 5438).
- `user.topic` columns (server view, Plan 1): name, team_id, announce, join_policy, auto_maintained, key, is_admin, is_member, opted_out, can_post, can_manage, member_contact_ids (+ base id/updated_at/seq/archived_at).

## Scope note
**Sync-IN only for `thread.topic_id`.** topicId is synced from the server and readable on the client. The client→server SEND of topic_id (compose flow) is intentionally OUT of scope here: it's UI-triggered, and adding topic_id to the thread push (`toBase`) prematurely risks the server's `p_thread ? 'topic_id'` CASE wiping topic_id to null on every unrelated thread update. Wire the send with the compose UI. (Task 5 already made the server accept it.)

---

## Task 1: Drift schema — Topics table, Group/Thread columns, migration, codegen

**Files:**
- Create: `apps/plot/lib/store/topic.dart`
- Modify: `apps/plot/lib/store/store.dart` (add `part 'topic.dart';`; migration block; `schemaVersion`)
- Modify: `apps/plot/lib/store/group.dart` (add `privacy`, `canAddress` columns)
- Modify: `apps/plot/lib/store/thread.dart` (add `topicId` column + accessor)

- [ ] **Step 1: Create `apps/plot/lib/store/topic.dart`** (mirror `group.dart`):

```dart
part of 'store.dart';

@DataClassName('TopicRow')
class Topics extends Table with SyncableTable, UuidTable, DeletableTable {
  TextColumn get name => text()();

  /// Stable identifier for system topics (e.g. `@plot.updates`). Null for
  /// user-created topics.
  TextColumn get key => text().nullable()();
  TextColumn get joinPolicy => text()();
  IntColumn get teamId => integer().nullable()();
  BoolColumn get announce => boolean().withDefault(const Constant(false))();
  BoolColumn get autoMaintained =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isAdmin => boolean().withDefault(const Constant(false))();
  BoolColumn get isMember => boolean().withDefault(const Constant(false))();

  /// The viewing user has left this topic (opted out). The topic stays visible
  /// (so they can rejoin) but they don't receive its thread stream.
  BoolColumn get optedOut => boolean().withDefault(const Constant(false))();

  /// May the user post threads to this topic (admins always; non-announce
  /// members).
  BoolColumn get canPost => boolean().withDefault(const Constant(false))();

  /// May the user edit the topic's membership (admins; open-join members).
  BoolColumn get canManage => boolean().withDefault(const Constant(false))();
  TextColumn get memberContactIds =>
      text().nullable().map(const UuidListConverter())();
}

class TopicsBase extends BaseTable {
  TopicsBase() : super(table: 'user_topic', syncEndpoint: 'topics');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('Topic is read-only');
  }

  @override
  Insertable<TopicRow> fromBase(Map<String, dynamic> json) {
    return TopicRow.fromJson(json);
  }
}

class Topic {
  static TableInfo<Topics, TopicRow> get table => Store.get.topics;

  // In-memory cache for synchronous lookups (topics are few per user).
  static final Map<Uuid, TopicRow> _cache = {};

  static Future<void> pull() async {
    await Store.get.pull(table, TopicsBase(), initial: true);
    await Store.get.pull(table, TopicsBase());
    await _refreshCache();
  }

  static Future<void> _refreshCache() async {
    final rows = await Store.get.select(table).get();
    _cache
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r.id, r)));
  }

  static TopicRow? fromCache(Uuid id) => _cache[id];

  /// Fetch a topic by id. Returns null if not visible/synced.
  static Future<TopicRow?> getOne(Uuid id) async {
    final cached = _cache[id];
    if (cached != null) return cached;
    final row =
        await (Store.get.select(table)
              ..where((t) => t.id.equals(id.toBytes()))
              ..limit(1))
            .getSingleOrNull();
    if (row != null) _cache[row.id] = row;
    return row;
  }

  static Stream<TopicRow?> watchOne(Uuid id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Topics the user can post to, filtered by [search] against name. Computed
  /// from local `is_member`/`is_admin`/`announce`/`opted_out` columns (so it
  /// works immediately after a schema migration). Admins can always post;
  /// non-admins only to non-announce topics they're a member of and haven't
  /// left.
  static Future<List<TopicRow>> getPostable({String? search}) async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            t.optedOut.equals(false) &
            (t.isAdmin.equals(true) |
                (t.isMember.equals(true) & t.announce.equals(false))),
      );
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      query.where((t) => t.name.like('$lower%') | t.name.like('% $lower%'));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }
}
```

- [ ] **Step 2: Register the part file** — in `apps/plot/lib/store/store.dart`, add `part 'topic.dart';` next to `part 'group.dart';` (~line 86).

- [ ] **Step 3: Add columns to `Groups`** — in `apps/plot/lib/store/group.dart`, add after `canPost`:

```dart
  /// Group privacy: `open` (members see roster + can address) or `private`
  /// (admins only). Synced from `user.group.privacy`.
  TextColumn get privacy => text().nullable()();

  /// May the user add this group to a thread/topic. Synced from
  /// `user.group.can_address` (admins always; open-privacy members).
  BoolColumn get canAddress => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 4: Add `topicId` to `Threads`** — in `apps/plot/lib/store/thread.dart`, add to the `Threads` table (near the other nullable-uuid columns, e.g. after `mergedIntoThreadId`):

```dart
  /// The topic (channel) this thread belongs to. Synced in from
  /// `user.thread.topic_id`; drives the thread's topic membership/routing.
  BlobColumn get topicId => blob().nullable().map(const UuidConverter())();
```

And add a read accessor on the `Thread` model (near `topic`/`mergedIntoThreadId` accessors, ~line 4854/5438):

```dart
  Uuid? get topicId => _thread.topicId;
```

- [ ] **Step 5: Migration + schemaVersion** — in `apps/plot/lib/store/store.dart`'s `onUpgrade`, after the `if (from < 355)` block, add:

```dart
    if (from < 356) {
      await m.createTable(topics);
      await m.addColumn(groups, groups.privacy);
      await m.addColumn(groups, groups.canAddress);
      await m.addColumn(threads, threads.topicId);
    }
```

And bump `int get schemaVersion => 355;` → `356`.

- [ ] **Step 6: Codegen** — `cd apps/plot && dart run build_runner build --delete-conflicting-outputs`. Expect success (generates `Topics`/`TopicRow`, the new columns, `Store.get.topics`).

- [ ] **Step 7: Analyze** — `cd apps/plot && flutter analyze lib/store/topic.dart lib/store/group.dart lib/store/thread.dart lib/store/store.dart`. Expect no errors (info/warnings tolerated; CI lint is `flutter analyze --no-fatal-infos`). NOTE: adding nullable / defaulted columns does NOT break `RowClass` constructors; if a "missing required argument" analyze error appears app-wide, a column was declared non-nullable without a default — fix it.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/store/topic.dart apps/plot/lib/store/group.dart \
        apps/plot/lib/store/thread.dart apps/plot/lib/store/store.dart \
        apps/plot/lib/store/store.g.dart
git commit -m "feat(app): TopicRow store + Group.privacy/canAddress + Thread.topicId (Drift schema 356)"
```
(Husky may block a Dart-only commit in a Flutter-only worktree — use `--no-verify` if so, per the project worktree note.)

---

## Task 2: Sync registration

**Files:**
- Modify: `apps/plot/lib/store/sync_orchestrator.dart`

- [ ] **Step 1: Add the `topic` SyncEntity** — next to the `group` entity (~line 52):

```dart
  /// Topic entity (read-only, no dependencies). The client is on apiVersion 4,
  /// so /sync/topics returns the new topic entity (user.topic), not the legacy
  /// group-compat shape.
  static final topic = SyncEntity(
    debugName: 'topic',
    dependsOn: [],
    pushFn: () async => true, // Read-only, skip push
    pullFn: Topic.pull,
  );
```

- [ ] **Step 2: Register in `allEntities`** — add `topic,` to the `static final allEntities = [ … ]` list (~line 149), next to `group,`.

- [ ] **Step 3: Update the name→entity switch** (~line 242). It currently maps `'user_group' || 'group' || 'user_topic' || 'topic' => group` (a legacy alias from when groups were called topics). Read the switch's full context first. Now that a real topic entity exists, route the topic names to it: change that arm to `'user_group' || 'group' => group,` and add `'user_topic' || 'topic' => topic,`. If the switch's purpose makes this risky (e.g. it's used only for legacy invalidation and `user_topic` must stay mapped to group for back-compat), keep `group` and instead document why — but the default correct mapping is `user_topic`/`topic` → the topic entity. Verify nothing else in the file assumes `user_topic → group`.

- [ ] **Step 4: Analyze (full store + orchestrator)** — `cd apps/plot && flutter analyze lib/store/`. Expect no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/sync_orchestrator.dart
git commit -m "feat(app): register topic sync entity (pull /sync/topics)"
```

---

## Task 3: Full analyze + verification

- [ ] **Step 1: Full app analyze** — `cd apps/plot && flutter analyze 2>&1 | tail -20`. Confirm no NEW errors vs the baseline (the repo may have pre-existing infos/warnings; CI uses `--no-fatal-infos`, so the gate is zero `error •`). Pay attention to any thread/group construction site that now needs `topicId`/`privacy`/`canAddress` — they're nullable/defaulted so should not break, but confirm.

- [ ] **Step 2: Commit any fixes** (if needed).

---

## Self-Review

**Spec coverage (Plan 4):** TopicRow store + `/sync/topics` pull (T1, T2) ✅; `GroupRow.privacy`/`canAddress` (T1) ✅; `ThreadRow.topicId` synced-in + accessor (T1) ✅; sync registration (T2) ✅. **Deferred (noted):** client→server `topic_id` SEND on thread create (UI-coupled). Plan 5 = data migration (Everyone→Plot Users, Plot Updates topic, onboarding).

**Placeholder note:** Task 1's `topic.dart` is complete (mirrors `group.dart`); the column/migration/accessor edits are precise against grounded line refs. Tasks 2–3 are precise edits + verification.

**Risk notes:** (1) Non-nullable Drift column without default breaks `RowClass` constructors app-wide — all new columns here are nullable or defaulted (safe). (2) The sync_orchestrator line-242 name mapping must move `user_topic`/`topic` from `group` to the new `topic` entity — verify no other code relied on the legacy alias. (3) `schemaVersion` bump must be exactly one step (355→356) with the migration block, or migrations silently skip (per app AGENTS.md). (4) Worktree must be Flutter-bootstrapped (pub get + build_runner + app.env) before analyze works.
