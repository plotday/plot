# Per-source-focus Move ordering (cross-device) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Order the Move modal's destination focuses by which focuses the user has recently moved threads into *from the current source focus*, persisted across devices.

**Architecture:** Replace the global, session-only `MoveRecency` MRU with a per-source-focus affinity map persisted on the synced `user_settings` row (`move_affinity` jsonb, deep-merged per cell by max timestamp). The pure tier sort `orderMoveTargets` is unchanged — it is simply fed the per-source destination list instead of the global MRU. Reads come from the local Drift copy (offline-safe); writes are local-first with a fire-and-forget sync push.

**Tech Stack:** Flutter/Dart + Drift (client), PostgreSQL + Atlas migrations + Hono/Cloudflare Workers (server), Twister unaffected.

**Spec:** `docs/superpowers/specs/2026-06-22-per-source-focus-move-ordering-design.md`

## Global Constraints

- **Worktree + isolated DB.** This plan changes the DB schema. Work in a git worktree and run `bash scripts/worktree-db` before any DB command. Before every `pnpm gen-migration` / `pnpm apply-migrations` / `psql`, verify the port: `psql "$DATABASE_URL" -tAc "show port;"` must print the worktree port (NOT 54322). If `$DATABASE_URL` is stale, source it: `source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"`.
- **Schema is source of truth.** Edit `libs/db/schema/` files only; never hand-edit migrations or `src/types.ts`. Generate migrations with `pnpm gen-migration`. Commit the regenerated `libs/db/src/types.ts`.
- **Expand-only migration.** Adding a `jsonb NOT NULL DEFAULT '{}'` column is a safe single expand migration (column with a default). No contract needed.
- **Backwards compatibility.** Older app versions POST `/sync/user-settings` without `move_affinity`; the server upsert MUST treat a missing/`NULL` value as "no change" (never wipe). GET adds a field old clients ignore.
- **Drift migrations are incremental.** Current `schemaVersion` is `374`; the last reset was v243. Add `if (from < 375)` and bump to `375`. Never drop-and-recreate.
- **forui + no material.** Client code imports only `flutter/widgets.dart` and `forui/forui.dart`. (No UI is added here, but applies if touched.)
- **Error capture.** New `catch` blocks for *unexpected* errors call `Tracker.captureException`. An offline sync-push failure is *expected* — log at `warning`, do not capture.
- **Lint gates.** `cd apps/plot && flutter analyze` (client); `pnpm --filter @plotday/api lint` and `pnpm --filter @plotday/db lint` (server) must pass before a task is complete.

---

### Task 1: Pure `MoveAffinity` model + `sharedSourceFocusId`

Adds the pure, testable core: the affinity map model and the bulk source-sharing helper. Additive — `MoveRecency` and `orderMoveTargets` are untouched, so the app still compiles and all existing tests pass. Task 5 switches callers over and removes `MoveRecency`.

**Files:**
- Modify: `apps/plot/lib/state/move_recency.dart`
- Test: `apps/plot/test/state/move_affinity_test.dart` (create)

**Interfaces:**
- Produces:
  - `class MoveAffinity` with: `factory MoveAffinity.fromMap(Map<String, dynamic>? raw)`, `List<Uuid> destsFor(Uuid source)` (newest-first), `MoveAffinity recordMove(Uuid source, Uuid dest, DateTime at)` (returns a new instance, source list re-capped to `MoveAffinity.maxPerSource` = 8), `Map<String, dynamic> toMap()`, and `static const int maxPerSource = 8`.
  - `Uuid? sharedSourceFocusId(Iterable<Uuid> sourceIds)` — the single shared source id, or `null` when the iterable is empty or spans >1 id.

- [ ] **Step 1: Write the failing tests**

Create `apps/plot/test/state/move_affinity_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/move_recency.dart';
import 'package:plot/util/uuid.dart';

void main() {
  group('MoveAffinity', () {
    test('fromMap tolerates null / empty / malformed → empty', () {
      expect(MoveAffinity.fromMap(null).destsFor(Uuid.generate()), isEmpty);
      expect(MoveAffinity.fromMap(<String, dynamic>{}).destsFor(Uuid.generate()),
          isEmpty);
      // Malformed nested value: not a map → ignored, no throw.
      final s = Uuid.generate();
      final a = MoveAffinity.fromMap({s.toString(): 'garbage'});
      expect(a.destsFor(s), isEmpty);
    });

    test('destsFor returns destinations newest-first', () {
      final s = Uuid.generate();
      final older = Uuid.generate();
      final newer = Uuid.generate();
      final a = MoveAffinity.fromMap({
        s.toString(): {
          older.toString(): 100,
          newer.toString(): 200,
        },
      });
      expect(a.destsFor(s).map((u) => u.toString()),
          [newer.toString(), older.toString()]);
    });

    test('destsFor is scoped to the source (other sources excluded)', () {
      final s1 = Uuid.generate();
      final s2 = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      final a = MoveAffinity.fromMap({
        s1.toString(): {d1.toString(): 100},
        s2.toString(): {d2.toString(): 100},
      });
      expect(a.destsFor(s1).map((u) => u.toString()), [d1.toString()]);
      expect(a.destsFor(s2).map((u) => u.toString()), [d2.toString()]);
    });

    test('recordMove adds a new cell and moves it to the front', () {
      final s = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      var a = MoveAffinity.fromMap(null);
      a = a.recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(100));
      a = a.recordMove(s, d2, DateTime.fromMillisecondsSinceEpoch(200));
      expect(a.destsFor(s).map((u) => u.toString()),
          [d2.toString(), d1.toString()]);
    });

    test('recordMove updates an existing cell timestamp (re-floats it)', () {
      final s = Uuid.generate();
      final d1 = Uuid.generate();
      final d2 = Uuid.generate();
      var a = MoveAffinity.fromMap(null)
          .recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(100))
          .recordMove(s, d2, DateTime.fromMillisecondsSinceEpoch(200));
      // Re-move d1 with a newer time → d1 floats above d2.
      a = a.recordMove(s, d1, DateTime.fromMillisecondsSinceEpoch(300));
      expect(a.destsFor(s).map((u) => u.toString()),
          [d1.toString(), d2.toString()]);
    });

    test('recordMove caps a source to maxPerSource newest destinations', () {
      final s = Uuid.generate();
      var a = MoveAffinity.fromMap(null);
      final dests = <Uuid>[];
      for (var i = 0; i < MoveAffinity.maxPerSource + 3; i++) {
        final d = Uuid.generate();
        dests.add(d);
        a = a.recordMove(s, d, DateTime.fromMillisecondsSinceEpoch(1000 + i));
      }
      final result = a.destsFor(s);
      expect(result.length, MoveAffinity.maxPerSource);
      // The 3 oldest were dropped; the newest survive, newest-first.
      expect(result.first.toString(), dests.last.toString());
      expect(result.map((u) => u.toString()),
          isNot(contains(dests.first.toString())));
    });

    test('toMap ↔ fromMap round-trips', () {
      final s = Uuid.generate();
      final d = Uuid.generate();
      final a =
          MoveAffinity.fromMap(null).recordMove(s, d, DateTime.fromMillisecondsSinceEpoch(123));
      final round = MoveAffinity.fromMap(a.toMap());
      expect(round.destsFor(s).map((u) => u.toString()), [d.toString()]);
    });
  });

  group('sharedSourceFocusId', () {
    test('single shared source → that id', () {
      final s = Uuid.generate();
      expect(sharedSourceFocusId([s, s, s])?.toString(), s.toString());
    });
    test('multiple distinct sources → null', () {
      expect(sharedSourceFocusId([Uuid.generate(), Uuid.generate()]), isNull);
    });
    test('empty → null', () {
      expect(sharedSourceFocusId(const <Uuid>[]), isNull);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/state/move_affinity_test.dart`
Expected: FAIL — `MoveAffinity`/`sharedSourceFocusId` are undefined.

- [ ] **Step 3: Implement `MoveAffinity` + `sharedSourceFocusId`**

In `apps/plot/lib/state/move_recency.dart`, add the import for `Uuid` if not already present (the file imports `store.dart`, which re-exports `Uuid`; keep as-is) and append the following ABOVE `orderMoveTargets` (leave `MoveRecency`, `orderMoveTargets`, and `sharedRoleId` exactly as they are):

```dart
/// Cross-device per-source-focus move affinity. Wraps the JSON map stored on
/// `user_settings.move_affinity`, shaped
/// `{ "<sourceFocusId>": { "<destFocusId>": <epochMillis> } }`. Immutable;
/// [recordMove] returns a new instance. Drives the Move modal's recency tier:
/// destinations recently moved into *from the current focus*, newest first.
class MoveAffinity {
  MoveAffinity._(this._bySource);

  /// Max destinations retained per source focus (older ones are dropped on
  /// write — ordering relevance falls off quickly).
  static const int maxPerSource = 8;

  // { source : { dest : epochMillis } }, owned/immutable.
  final Map<Uuid, Map<Uuid, int>> _bySource;

  /// Tolerant parse: null / empty / malformed entries yield an empty map and
  /// never throw (the Move modal must order even with garbage on disk).
  factory MoveAffinity.fromMap(Map<String, dynamic>? raw) {
    final parsed = <Uuid, Map<Uuid, int>>{};
    if (raw != null) {
      for (final entry in raw.entries) {
        final dests = entry.value;
        if (dests is! Map) continue;
        final Uuid source;
        try {
          source = Uuid.fromString(entry.key);
        } catch (_) {
          continue;
        }
        final destMap = <Uuid, int>{};
        for (final d in dests.entries) {
          final at = d.value;
          if (at is! num) continue;
          try {
            destMap[Uuid.fromString(d.key as String)] = at.toInt();
          } catch (_) {
            // Skip unparseable dest id.
          }
        }
        if (destMap.isNotEmpty) parsed[source] = destMap;
      }
    }
    return MoveAffinity._(parsed);
  }

  /// Destinations recently moved into from [source], newest first.
  List<Uuid> destsFor(Uuid source) {
    final dests = _bySource[source];
    if (dests == null) return const [];
    final entries = dests.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)); // newest (largest ms) first
    return [for (final e in entries) e.key];
  }

  /// A new instance recording a move from [source] to [dest] at [at], with the
  /// source's destination list re-capped to [maxPerSource] newest entries.
  MoveAffinity recordMove(Uuid source, Uuid dest, DateTime at) {
    final next = <Uuid, Map<Uuid, int>>{
      for (final e in _bySource.entries) e.key: Map<Uuid, int>.from(e.value),
    };
    final dests = next.putIfAbsent(source, () => <Uuid, int>{});
    dests[dest] = at.millisecondsSinceEpoch;
    if (dests.length > maxPerSource) {
      final kept = dests.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      next[source] = {
        for (final e in kept.take(maxPerSource)) e.key: e.value,
      };
    }
    return MoveAffinity._(next);
  }

  /// Serialize back to the `user_settings.move_affinity` JSON shape.
  Map<String, dynamic> toMap() => {
        for (final s in _bySource.entries)
          s.key.toString(): {
            for (final d in s.value.entries) d.key.toString(): d.value,
          },
      };
}

/// The source focus shared by an entire bulk selection, or null when the
/// selection is empty or spans more than one source focus. Mirrors
/// [sharedRoleId]: the per-source recency tier only applies to a bulk move
/// when every selected thread sits in the same source focus.
Uuid? sharedSourceFocusId(Iterable<Uuid> sourceIds) {
  final distinct = sourceIds.toSet();
  return distinct.length == 1 ? distinct.first : null;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/move_affinity_test.dart`
Expected: PASS (all cases).

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/state/move_recency.dart test/state/move_affinity_test.dart`
Expected: No issues. (Existing `move_recency_test.dart` and `order_move_targets_test.dart` still pass — `MoveRecency` and `orderMoveTargets` are untouched.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/move_recency.dart apps/plot/test/state/move_affinity_test.dart
git commit -m "feat(app): add MoveAffinity per-source model + sharedSourceFocusId"
```

---

### Task 2: Server schema — `move_affinity` column, merge function, upsert param

Adds the synced column, the per-cell max-merge helper, and threads `p_move_affinity` through `user.upsert_user_settings` with no-wipe semantics. GET needs no change (it already `selectAll()`s the table).

**Files:**
- Modify: `libs/db/schema/50-tables/99-user-settings.sql`
- Create: `libs/db/schema/40-functions/06-move-affinity.sql`
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql:762-836` (the `user.upsert_user_settings` function)
- Generated: a new file under `libs/db/migrations/` + updated `libs/db/src/types.ts` (via tooling — do not hand-edit)

**Interfaces:**
- Produces: column `public.user_settings.move_affinity jsonb NOT NULL DEFAULT '{}'`; function `public.merge_move_affinity(existing jsonb, incoming jsonb) RETURNS jsonb`; new param `p_move_affinity jsonb DEFAULT NULL` on `user.upsert_user_settings` (appended last, so existing positional/named callers are unaffected).

- [ ] **Step 1: Add the column**

In `libs/db/schema/50-tables/99-user-settings.sql`, add this column definition immediately after the `tracking_paused_at` column block (before `event_sessions_finalized_through`):

```sql
    -- Cross-device per-source-focus move affinity. JSON map
    -- `{ "<source_focus_id>": { "<dest_focus_id>": <epoch_ms> } }`. Drives the
    -- Move modal's recency tier (destinations recently moved into from the
    -- current focus). Deep-merged per cell keeping the max timestamp in
    -- upsert_user_settings so two devices' concurrent offline moves both
    -- survive; NULL incoming = no change (old clients never wipe it).
    "move_affinity" jsonb NOT NULL DEFAULT '{}'::jsonb,
```

- [ ] **Step 2: Add the merge function**

Create `libs/db/schema/40-functions/06-move-affinity.sql`:

```sql
-- Deep-merge two move-affinity maps of shape
--   { "<source_focus_id>": { "<dest_focus_id>": <epoch_ms> } }
-- keeping the MAX epoch per (source, dest) cell. Used by
-- user.upsert_user_settings so two devices' concurrent offline moves both
-- survive (neither clobbers the other). Pure jsonb; no table dependencies, so
-- it lives in 40-functions (loaded before the user-schema upserts). PUBLIC
-- keeps default EXECUTE, matching the other helpers here.
CREATE OR REPLACE FUNCTION public.merge_move_affinity (existing jsonb, incoming jsonb)
    RETURNS jsonb
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT COALESCE(jsonb_object_agg(src, dests), '{}'::jsonb)
    FROM (
        SELECT s_key AS src, jsonb_object_agg(d_key, ms) AS dests
        FROM (
            SELECT s.key AS s_key, d.key AS d_key, max((d.value::text)::numeric) AS ms
            FROM (
                SELECT key, value FROM jsonb_each(COALESCE(existing, '{}'::jsonb))
                UNION ALL
                SELECT key, value FROM jsonb_each(COALESCE(incoming, '{}'::jsonb))
            ) s,
            LATERAL jsonb_each(s.value) d
            GROUP BY s.key, d.key
        ) cells
        GROUP BY s_key
    ) per_source;
$function$;
```

- [ ] **Step 3: Thread `p_move_affinity` through the upsert**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, edit `user.upsert_user_settings`:

3a. Add the parameter after `p_dismissed_focus_suggestions jsonb DEFAULT NULL` (keep it last):

```sql
    -- jsonb move-affinity map to merge. NULL = no change (old clients never
    -- wipe it). Non-null is deep-merged per cell keeping the max timestamp.
    p_move_affinity jsonb DEFAULT NULL
```

3b. In the `INSERT INTO user_settings (...)` column list, add `move_affinity`:

```sql
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed, tracking_paused_at, dismissed_focus_suggestions, move_affinity)
```

3c. In the `VALUES (...)` list, add the affinity value as the final value (after the `COALESCE(p_dismissed_focus_suggestions, '[]'::jsonb)` line):

```sql
            COALESCE(p_move_affinity, '{}'::jsonb)
```

3d. In the `ON CONFLICT (user_id) DO UPDATE SET` clause, add this assignment (immediately before `updated_at = now()`):

```sql
            -- Deep-merge per cell, keeping the newest timestamp. NULL incoming
            -- preserves the stored map (old clients never wipe it).
            move_affinity = CASE
                WHEN p_move_affinity IS NULL THEN user_settings.move_affinity
                ELSE public.merge_move_affinity(user_settings.move_affinity, p_move_affinity)
            END,
```

- [ ] **Step 4: Generate, apply, and regenerate types**

```bash
cd libs/db
psql "$DATABASE_URL" -tAc "show port;"   # must be the worktree port, not 54322
pnpm gen-migration -- add_user_settings_move_affinity
pnpm apply-migrations                      # also regenerates src/types.ts
pnpm diff-schema-migrations                # expected: no differences
```
Expected: a new migration appears under `libs/db/migrations/`; apply succeeds; diff reports no differences.

- [ ] **Step 5: Verify the merge function and no-wipe semantics with psql**

```bash
# 5a. merge-max: existing d1=100,d2=200 ; incoming d1=150 + new source s2.
psql "$DATABASE_URL" -tAc "SELECT public.merge_move_affinity(
  '{\"s1\": {\"d1\": 100, \"d2\": 200}}'::jsonb,
  '{\"s1\": {\"d1\": 150}, \"s2\": {\"d3\": 50}}'::jsonb);"
# Expected (key order may vary): {"s1": {"d1": 150, "d2": 200}, "s2": {"d3": 50}}

# 5b. empty inputs → empty object.
psql "$DATABASE_URL" -tAc "SELECT public.merge_move_affinity('{}'::jsonb, '{}'::jsonb);"
# Expected: {}

# 5c. upsert no-wipe: a NULL p_move_affinity preserves an existing map
#     (rolled back so it does not mutate local dev data).
psql "$DATABASE_URL" <<'SQL'
BEGIN;
WITH u AS (SELECT id FROM public."user" LIMIT 1)
SELECT ("user".upsert_user_settings(
          (SELECT id FROM u), NULL,
          p_move_affinity => '{"s1":{"d9":999}}'::jsonb)).move_affinity AS first_write;
WITH u AS (SELECT id FROM public."user" LIMIT 1)
SELECT ("user".upsert_user_settings((SELECT id FROM u), NULL)).move_affinity AS after_null;
ROLLBACK;
SQL
# Expected: first_write contains "d9":999 ; after_null still contains "d9":999
#           (the NULL call merged nothing and preserved it).
```
Expected: outputs match the comments above.

- [ ] **Step 6: Lint the db package**

Run: `pnpm --filter @plotday/db lint`
Expected: PASS (types are in sync — `pnpm apply-migrations` regenerated `src/types.ts`).

- [ ] **Step 7: Commit**

```bash
git add libs/db/schema libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): user_settings.move_affinity column + merge + upsert no-wipe"
```

---

### Task 3: Server endpoint forwards `p_move_affinity`

Wire the POST handler to pass `move_affinity` from the request body into the upsert. GET already returns the column via `selectAll()` — no change.

**Files:**
- Modify: `workers/api/src/app/sync/user-settings.ts:52-74` (POST handler)

**Interfaces:**
- Consumes: `user.upsert_user_settings(..., p_move_affinity)` from Task 2 (now present in regenerated types).

- [ ] **Step 1: Forward the field**

In `workers/api/src/app/sync/user-settings.ts`, inside the `rpcUser(trx, "upsert_user_settings", { ... })` object, add a final property after `p_dismissed_focus_suggestions`:

```ts
      // Deep-merged server-side per (source,dest) cell; null = no change.
      p_move_affinity: body.move_affinity ?? null,
```

- [ ] **Step 2: Typecheck / lint**

Run: `pnpm --filter @plotday/api lint`
Expected: PASS. (If `p_move_affinity` is reported as an unknown key, the regenerated types from Task 2 were not committed — re-run Task 2 Step 4.)

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/sync/user-settings.ts
git commit -m "feat(api): forward move_affinity to upsert_user_settings"
```

---

### Task 4: Client Drift column + JSON converter

Adds the local `move_affinity` column mirroring `dismissed_focus_suggestions`: a `JsonTypeConverter2` that stores JSON text in SQLite and a JSON object over the sync wire. `use_sql_column_name_as_json_key: true` maps the `moveAffinity` getter to the `move_affinity` SQL column and JSON key, matching the server.

**Files:**
- Create: `apps/plot/lib/util/json_map_converter.dart`
- Test: `apps/plot/test/util/json_map_converter_test.dart` (create)
- Modify: `apps/plot/lib/store/store.dart` (add import; bump `schemaVersion`; add migration step)
- Modify: `apps/plot/lib/store/user_settings.dart` (add column)
- Generated: `apps/plot/lib/store/store.g.dart` (via build_runner — do not hand-edit)

**Interfaces:**
- Produces: `class JsonMapConverter` (`TypeConverter<Map<String, dynamic>, String>` with `JsonTypeConverter2<Map<String, dynamic>, String, Map<String, dynamic>>`); Drift getter `UserSettings.moveAffinity` → non-null `Map<String, dynamic>` (default `{}`); `UserSettingsRow.moveAffinity`.

- [ ] **Step 1: Write the failing converter test**

Create `apps/plot/test/util/json_map_converter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/json_map_converter.dart';

void main() {
  const c = JsonMapConverter();

  test('toSql / fromSql round-trip', () {
    final map = {
      's1': {'d1': 100, 'd2': 200},
    };
    final sql = c.toSql(map);
    expect(c.fromSql(sql), map);
  });

  test('fromSql tolerates empty string → empty map', () {
    expect(c.fromSql(''), <String, dynamic>{});
  });

  test('toJson / fromJson pass the object through (sync wire)', () {
    final map = {
      's1': {'d1': 100},
    };
    expect(c.toJson(map), map);
    expect(c.fromJson(map), map);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/plot && flutter test test/util/json_map_converter_test.dart`
Expected: FAIL — `JsonMapConverter` is undefined.

- [ ] **Step 3: Implement the converter**

Create `apps/plot/lib/util/json_map_converter.dart`:

```dart
import 'dart:convert';

import 'package:drift/drift.dart';

/// Stores a JSON object as an encoded string in SQLite and as a JSON object
/// over the sync wire (matching the server's jsonb columns). Mirrors
/// [StringListConverter] in `string_list_converter.dart` but for a map payload
/// (e.g. `user_settings.move_affinity`).
class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String>
    with
        JsonTypeConverter2<Map<String, dynamic>, String,
            Map<String, dynamic>> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const {};
    final decoded = jsonDecode(fromDb);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  String toSql(Map<String, dynamic> value) => jsonEncode(value);

  @override
  Map<String, dynamic> fromJson(Map<String, dynamic> json) => json;

  @override
  Map<String, dynamic> toJson(Map<String, dynamic> value) => value;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/util/json_map_converter_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the Drift column**

In `apps/plot/lib/store/user_settings.dart`, add this getter inside the `UserSettings` table class, immediately after the `trackingPausedAt` getter (before the `primaryKey` override):

```dart
  /// Cross-device per-source-focus move affinity. JSON map
  /// `{ sourceFocusId: { destFocusId: epochMillis } }`. The server deep-merges
  /// per cell keeping the max timestamp; the client caps each source to its 8
  /// most-recent destinations. Drives the Move modal's recency tier.
  TextColumn get moveAffinity =>
      text().map(const JsonMapConverter()).withDefault(const Constant('{}'))();
```

- [ ] **Step 6: Import the converter + bump schema version + add migration**

In `apps/plot/lib/store/store.dart`:

6a. Add the import alongside the other `util/` converter imports (near the `string_list_converter.dart` / `uuid.dart` imports):

```dart
import 'package:plot/util/json_map_converter.dart';
```

6b. Change `int get schemaVersion => 374;` to:

```dart
  int get schemaVersion => 375;
```

6c. In `Store.migration.onUpgrade`, after the last existing `if (from < 374) { ... }` block, add:

```dart
    if (from < 375) {
      // Cross-device per-source-focus move affinity (Move modal recency tier).
      // Non-null TEXT with a '{}' default; existing rows get the empty map.
      await _safeAddColumn(m, userSettings, userSettings.moveAffinity);
    }
```

- [ ] **Step 7: Regenerate Drift code**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: completes; `lib/store/store.g.dart` now contains a `move_affinity` column for `user_settings`.

- [ ] **Step 8: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/user_settings.dart lib/store/store.dart lib/util/json_map_converter.dart`
Expected: No issues.

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/util/json_map_converter.dart \
        apps/plot/test/util/json_map_converter_test.dart \
        apps/plot/lib/store/user_settings.dart \
        apps/plot/lib/store/store.dart \
        apps/plot/lib/store/store.g.dart
git commit -m "feat(app): add move_affinity Drift column + JsonMapConverter (schema v375)"
```

---

### Task 5: Wire the Move modal to per-source affinity + remove `MoveRecency`

Switch the read path (modal ordering) and write path (move recording) to the persisted per-source affinity, then delete the now-unused `MoveRecency`. The pure ordering (`orderMoveTargets`) and model (`MoveAffinity`) are already tested; this task adds the bulk-coalescing helper (`movePairs`, TDD'd) and the thin I/O glue, verified by analyze + a run-app behavioral check.

**Files:**
- Modify: `apps/plot/lib/state/move_recency.dart` (add `movePairs`, `loadMoveAffinity`, `recordMoveAffinity`, `orderedMoveTargets`; remove `MoveRecency`)
- Modify: `apps/plot/lib/command/thread.dart` (read sites `:2390-2422` and `:2124-2151`; record sites in `MoveToPriority.run`, `_BulkMoveToPriority.run`, `_CreateAndMoveToNewPriority.run`; remove the record call in `_applyPriorityMove:2291`)
- Modify: `apps/plot/lib/state/root_provider.dart:278` (remove the `MoveRecency.instance.clear()` call)
- Delete: `apps/plot/test/state/move_recency_test.dart`
- Test: `apps/plot/test/state/move_affinity_test.dart` (extend with `movePairs` cases)

**Interfaces:**
- Consumes: `MoveAffinity`, `sharedSourceFocusId`, `orderMoveTargets`, `sharedRoleId` (move_recency.dart); `UserSettingsEntity.get/save`, `UserSettingsCompanion` (store.dart).
- Produces:
  - `List<(Uuid source, Uuid dest)> movePairs(Iterable<Uuid> sources, Uuid dest)` — distinct sources, each paired with `dest`, preserving first-seen order.
  - `Future<MoveAffinity> loadMoveAffinity()` — reads the local `user_settings` row.
  - `Future<void> recordMoveAffinity(List<(Uuid, Uuid)> pairs)` — local-first save; fire-and-forget push via `save()`; never throws.
  - `Future<List<Priority>> orderedMoveTargets({required List<Priority> focuses, required Uuid? sourceId, required Uuid? currentRoleId})`.

- [ ] **Step 1: Write the failing `movePairs` test**

Append to `apps/plot/test/state/move_affinity_test.dart` (inside `main()`, after the existing groups):

```dart
  group('movePairs', () {
    test('dedups distinct sources, each paired with the destination', () {
      final s1 = Uuid.generate();
      final s2 = Uuid.generate();
      final dest = Uuid.generate();
      final pairs = movePairs([s1, s1, s2, s1], dest);
      expect(pairs.length, 2);
      expect(pairs[0].$1.toString(), s1.toString());
      expect(pairs[0].$2.toString(), dest.toString());
      expect(pairs[1].$1.toString(), s2.toString());
    });

    test('empty sources → empty', () {
      expect(movePairs(const <Uuid>[], Uuid.generate()), isEmpty);
    });
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd apps/plot && flutter test test/state/move_affinity_test.dart`
Expected: FAIL — `movePairs` is undefined.

- [ ] **Step 3: Implement `movePairs` and the I/O glue**

In `apps/plot/lib/state/move_recency.dart`:

3a. Add a logger near the top of the file (after the imports):

```dart
import 'package:logging/logging.dart';

final Logger _log = Logger('plot.move_affinity');
```

3b. Add these top-level functions (e.g. just below `sharedSourceFocusId`):

```dart
/// Distinct source focuses from a bulk selection, each paired with the single
/// [dest]. Preserves first-seen order. Used to coalesce a bulk move so each
/// source records one affinity write rather than one per thread.
List<(Uuid source, Uuid dest)> movePairs(Iterable<Uuid> sources, Uuid dest) {
  final seen = <String>{};
  final pairs = <(Uuid, Uuid)>[];
  for (final s in sources) {
    if (seen.add(s.toString())) pairs.add((s, dest));
  }
  return pairs;
}

/// The user's persisted move affinity from the local `user_settings` row.
/// Offline-safe: a local Drift read, empty when the row/value is absent.
Future<MoveAffinity> loadMoveAffinity() async {
  final row = await UserSettingsEntity.get();
  return MoveAffinity.fromMap(row?.moveAffinity);
}

/// Record [pairs] (source → dest) into the persisted affinity, local-first.
/// `UserSettingsEntity.save` fire-and-forgets the sync push, so this is
/// offline-safe; any failure is logged, never thrown (callers fire-and-forget).
Future<void> recordMoveAffinity(List<(Uuid, Uuid)> pairs) async {
  if (pairs.isEmpty) return;
  try {
    var affinity = await loadMoveAffinity();
    final now = DateTime.now();
    for (final (source, dest) in pairs) {
      affinity = affinity.recordMove(source, dest, now);
    }
    await UserSettingsEntity.save(
      UserSettingsCompanion(moveAffinity: Value(affinity.toMap())),
    );
  } catch (e, st) {
    // Expected when offline / racing sign-out; the move itself already landed.
    _log.warning('Error recording move affinity', e, st);
  }
}

/// Order [focuses] for the Move modal: per-source recency (destinations moved
/// into from [sourceId]) → same role ([currentRoleId]) → base order. Reads the
/// persisted affinity locally (offline-safe).
Future<List<Priority>> orderedMoveTargets({
  required List<Priority> focuses,
  required Uuid? sourceId,
  required Uuid? currentRoleId,
}) async {
  final affinity = await loadMoveAffinity();
  return orderMoveTargets(
    focuses: focuses,
    recentMoves: sourceId == null ? const [] : affinity.destsFor(sourceId),
    currentRoleId: currentRoleId,
  );
}
```

3c. Remove the `MoveRecency` class entirely (the `class MoveRecency { ... }` block) and update the file's leading doc comment to describe the persisted affinity instead of the session MRU.

- [ ] **Step 4: Run the pure tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/move_affinity_test.dart test/state/order_move_targets_test.dart`
Expected: PASS. (`order_move_targets_test.dart` imports `move_recency.dart` but only uses `orderMoveTargets`, which is unchanged.)

- [ ] **Step 5: Wire the read sites in `thread.dart`**

5a. In `MoveThreadToPriority._getMoveCommands` (`apps/plot/lib/command/thread.dart`), replace the `orderMoveTargets(...)` call (the block currently reading `recentMoves: MoveRecency.instance.recent, currentRoleId: thread.priority.roleId`) with:

```dart
    final ordered = await orderedMoveTargets(
      focuses: focuses,
      sourceId: thread.priority.id,
      currentRoleId: thread.priority.roleId,
    );
```

5b. In `BulkMove._getBulkMoveCommands`, replace the `orderMoveTargets(...)` call with:

```dart
    final ordered = await orderedMoveTargets(
      focuses: priorities,
      sourceId: sharedSourceFocusId(threads.map((t) => t.priority.id)),
      currentRoleId: sharedRoleId(threads.map((t) => t.priority.roleId)),
    );
```

5c. Update the stale tier comments in both methods (they reference "moved-into this session (MRU)") to: "Tier 1: destinations recently moved into from the current focus; Tier 2: same-role focuses; Tier 3: base order."

- [ ] **Step 6: Wire the record sites in `thread.dart`**

6a. In `_applyPriorityMove`, delete the line `MoveRecency.instance.record(priority.id);` and its preceding comment (`// Remember this destination ...`).

6b. In `MoveToPriority.run`, before `return const CommandDone();`, add:

```dart
    unawaited(recordMoveAffinity([(thread.priority.id, priority!.id)]));
```

6c. In `_BulkMoveToPriority.run`, after the `for` loop and before `bloc?.clearSelection();`, add:

```dart
    unawaited(
      recordMoveAffinity(movePairs(threads.map((t) => t.priority.id), priority!.id)),
    );
```

6d. In `_CreateAndMoveToNewPriority.run`, after the `await _applyPriorityMove(...)` call and before `return const CommandDone();`, add:

```dart
    unawaited(recordMoveAffinity([(thread.priority.id, priority.id)]));
```

(`unawaited` is already imported and used in this file — see `_applyPriorityMove`.)

- [ ] **Step 7: Remove the `MoveRecency.clear()` call**

In `apps/plot/lib/state/root_provider.dart`, delete line 278 (`MoveRecency.instance.clear();`) and, if it leaves an unused `move_recency.dart` import, remove that import too. (Sign-out already clears the local store, including `user_settings`, so the persisted affinity resets with it.)

- [ ] **Step 8: Delete the obsolete `MoveRecency` test**

```bash
git rm apps/plot/test/state/move_recency_test.dart
```

- [ ] **Step 9: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: No issues. (Confirms no remaining `MoveRecency` references and that all call sites compile.)

- [ ] **Step 10: Run the app and verify behavior (run-app skill)**

Using the `run-app` skill, launch Plot.app and verify:
1. Open the Move modal on a thread in focus A; move it to focus C. Open the Move modal on another thread *in focus A* → C is at (or near) the top.
2. Move a thread in a *different* focus B → its modal does NOT float C to the top (recency is scoped to the source focus).
3. Fully quit and relaunch the app; repeat (1) → C is still ranked first for focus A (persistence works).
4. With the same focus having no prior moves, same-role focuses lead (role-affinity fallback).

Record the observed behavior. (The pure ordering/model are unit-tested; this confirms the I/O wiring and persistence end to end.)

- [ ] **Step 11: Commit**

```bash
git add apps/plot/lib/state/move_recency.dart apps/plot/lib/command/thread.dart \
        apps/plot/lib/state/root_provider.dart apps/plot/test/state/move_affinity_test.dart
git rm apps/plot/test/state/move_recency_test.dart
git commit -m "feat(app): order Move modal by per-source focus affinity; drop MoveRecency"
```

---

## Self-Review

**Spec coverage:**
- Tier 0 = per-source recency, Tier 1 = same role, Tier 2 = base → Task 5 Steps 3b/5 (`orderedMoveTargets` feeds `destsFor(sourceId)` into the unchanged `orderMoveTargets`). ✓
- Drop global recency tier → Task 5 (no global MRU; `MoveRecency` removed). ✓
- Persist on `user_settings.move_affinity` (jsonb) → Task 2 (column), Task 4 (Drift). ✓
- Per-cell max-merge, NULL = no change → Task 2 (`merge_move_affinity` + upsert CASE) + Step 5 psql verification. ✓
- Cap 8 per source on write → Task 1 (`recordMove` re-cap, `maxPerSource = 8`). ✓
- Bulk: `sharedSourceFocusId` + coalesce per distinct source → Task 1 (`sharedSourceFocusId`) + Task 5 (`movePairs`, `_BulkMoveToPriority.run`). ✓
- Offline-safe read (local Drift, tolerant of null/garbage) → Task 1 (`fromMap`) + Task 5 (`loadMoveAffinity`). ✓
- Offline-safe write (local-first, fire-and-forget push, never throws) → Task 5 (`recordMoveAffinity` try/catch + `unawaited`). ✓
- `/sync/priority-moves` classifier signal untouched → not modified by any task. ✓
- GET returns the field for old clients to ignore → Task 2 note (selectAll, no change needed); backwards-compat no-wipe → Task 2 upsert CASE. ✓
- Stale (deleted-focus) cells inert → `orderMoveTargets` only ranks focuses present in `focuses`; covered by the unchanged read path. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every command shows expected output. ✓

**Type consistency:** `MoveAffinity.fromMap`/`toMap` (Map<String,dynamic>) ↔ Drift `moveAffinity` (Map<String,dynamic>, via `JsonMapConverter`) ↔ server `move_affinity` jsonb. `destsFor`/`recordMove`/`maxPerSource`, `sharedSourceFocusId`, `movePairs`, `loadMoveAffinity`, `recordMoveAffinity`, `orderedMoveTargets` names are used identically across Tasks 1 and 5. `orderMoveTargets` signature (`focuses`, `recentMoves`, `currentRoleId`) is unchanged and reused. `p_move_affinity` param name matches between Task 2 (SQL) and Task 3 (rpc call). ✓
