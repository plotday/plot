# Suggested focuses in the focus-creation flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn "Add a focus" into a picker offering a custom focus plus curated suggestions (prefilling the existing two-step create form), and hide each suggestion cross-device once the user has actually created a focus from it.

**Architecture:** Suggestions are a static Dart list with stable keys. A new `AddFocus` command loads the user's dismissed-key set, and either shows a `ShowCommands` picker (custom + remaining suggestions) or, when none remain, opens the create form directly. Dismissals are recorded only after a focus is saved, in a new synced `dismissed_focus_suggestions` jsonb column on `user_settings`; the server merges keys as a monotonic union so concurrent devices never un-dismiss.

**Tech Stack:** Flutter/Dart (Drift store, Bloc command framework), Cloudflare Workers (Hono + Kysely), PostgreSQL (Atlas migrations, pgTAP tests).

**Spec:** `docs/superpowers/specs/2026-06-09-focus-suggestions-in-create-flow-design.md`

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `libs/db/schema/50-tables/99-user-settings.sql` | `user_settings` table def | add `dismissed_focus_suggestions` column |
| `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` | `upsert_user_settings` RPC | accept + union-merge the new column |
| `libs/db/tests/60-user-settings-dismissed-suggestions.sql` | pgTAP for the RPC | **new** |
| `libs/db/migrations/*` + `libs/db/src/types.ts` | generated | **generated** |
| `workers/api/src/app/sync/user-settings.ts` | POST upsert endpoint | forward new field |
| `apps/plot/lib/util/string_list_converter.dart` | `List<String>` ⇄ SQL/JSON converter | **new** |
| `apps/plot/lib/store/user_settings.dart` | Drift `UserSettings` table | add column |
| `apps/plot/lib/store/store.dart` | schema version + migration | bump + addColumn step |
| `apps/plot/lib/command/focus_suggestions.dart` | `FocusPrefill`, `kFocusSuggestions`, `visibleFocusSuggestions`, `DismissedFocusSuggestions`, `mergeDismissed` | **new** |
| `apps/plot/lib/command/priority.dart` | create commands + `AddFocus` | move `FocusPrefill` out; add `AddFocus`; thread `suggestionKey`; record on save |
| `apps/plot/lib/widget/priorities_list.dart` | sidebar "Add a focus" | `NewFocus()` → `AddFocus()` |
| `apps/plot/lib/command/global.dart` | global palette | `NewFocus()` → `AddFocus()` |
| `apps/plot/lib/widget/onboarding/onboarding_roles.dart` | dead onboarding chips | **delete** |
| `apps/plot/lib/widget/onboarding/onboarding_steps.dart` | onboarding steps | remove dead import |
| `apps/plot/docs/updates.md` (repo `docs/updates.md`) | user-facing changelog | add a bullet |

Tests:
- `apps/plot/test/util/string_list_converter_test.dart` — converter round-trip.
- `apps/plot/test/command/focus_suggestions_test.dart` — list integrity, `visibleFocusSuggestions`, `mergeDismissed`.

---

## Task 1: DB — `dismissed_focus_suggestions` column + union-merge upsert + endpoint

**Files:**
- Modify: `libs/db/schema/50-tables/99-user-settings.sql`
- Modify: `libs/db/schema/90-user-schema/85-user-sync-upserts.sql:734-795`
- Modify: `workers/api/src/app/sync/user-settings.ts:52-72`
- Create: `libs/db/tests/60-user-settings-dismissed-suggestions.sql`
- Generated: `libs/db/migrations/*`, `libs/db/src/types.ts`

> **DB safety:** This is local-only. Before any DB command, verify the port:
> `psql "$DATABASE_URL" -tAc "show port;"` — must print `54322` in the main repo
> (a worktree prints its own port; never hardcode `54322`). See
> `libs/db/AGENTS.md` "Stale `$DATABASE_URL`".

- [ ] **Step 1: Add the column to the table schema**

In `libs/db/schema/50-tables/99-user-settings.sql`, add the column inside the
`CREATE TABLE` (immediately after the `"onboarding_completed" boolean,` line):

```sql
    "onboarding_completed" boolean,
    -- Stable keys of the curated focus suggestions the user has already acted
    -- on (created a focus from). Drives hiding those suggestions in the
    -- "Add a focus" picker. jsonb array of text keys; merged as a monotonic
    -- union in upsert_user_settings so a stale device never un-dismisses.
    "dismissed_focus_suggestions" jsonb DEFAULT '[]'::jsonb,
```

- [ ] **Step 2: Extend the `upsert_user_settings` function**

In `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`, replace the function
(lines 734-795) so it accepts and union-merges the new column. Full replacement:

```sql
CREATE OR REPLACE FUNCTION "user".upsert_user_settings (
    user_id uuid,
    p_enter_behavior enter_behavior,
    p_ai_enabled boolean DEFAULT NULL,
    p_onboarding_completed boolean DEFAULT NULL,
    -- Pass `'1970-01-01T00:00:00Z'::timestamptz` to clear (resume tracking).
    -- NULL leaves the value unchanged so an offline-only field update doesn't
    -- clobber a paused state set on another device.
    p_tracking_paused_at timestamptz DEFAULT NULL,
    -- jsonb array of suggestion keys to mark dismissed. NULL = no change.
    -- Merged as a union with the existing set (dismissals are monotonic).
    p_dismissed_focus_suggestions jsonb DEFAULT NULL
)
    RETURNS user_settings
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior, ai_enabled, onboarding_completed, tracking_paused_at, dismissed_focus_suggestions)
        VALUES (
            upsert_user_settings.user_id,
            p_enter_behavior,
            p_ai_enabled,
            p_onboarding_completed,
            CASE
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                ELSE p_tracking_paused_at
            END,
            COALESCE(p_dismissed_focus_suggestions, '[]'::jsonb)
        )
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            ai_enabled = EXCLUDED.ai_enabled,
            -- Once true, stay true: don't let a NULL from a device that hasn't
            -- pulled yet clobber completion set by another device.
            onboarding_completed = COALESCE(EXCLUDED.onboarding_completed, user_settings.onboarding_completed),
            tracking_paused_at = CASE
                -- Sentinel epoch means "explicit clear" (resume).
                WHEN p_tracking_paused_at = '1970-01-01T00:00:00Z'::timestamptz THEN NULL
                -- NULL from the client means "no change", preserve existing.
                WHEN p_tracking_paused_at IS NULL THEN user_settings.tracking_paused_at
                ELSE p_tracking_paused_at
            END,
            -- Union-merge: existing keys ∪ newly dismissed keys, deduped.
            -- NULL/empty incoming leaves the set unchanged. Never removes keys.
            dismissed_focus_suggestions = (
                SELECT COALESCE(jsonb_agg(DISTINCT e), '[]'::jsonb)
                FROM jsonb_array_elements_text(
                    COALESCE(user_settings.dismissed_focus_suggestions, '[]'::jsonb)
                    || COALESCE(EXCLUDED.dismissed_focus_suggestions, '[]'::jsonb)
                ) AS e
            ),
            updated_at = now()
    RETURNING * INTO v_row;

    -- Retroactive pause reconciliation: when pause was just set (or moved
    -- earlier), archive any non-archived 'event' session rows for this user
    -- whose recorded interval starts at or after the paused instant. Sessions
    -- of source='active' or 'manual' are user-authored and not touched.
    IF v_row.tracking_paused_at IS NOT NULL THEN
        UPDATE public.session
        SET archived_at = now()
        WHERE user_id = upsert_user_settings.user_id
            AND source = 'event'
            AND archived_at IS NULL
            AND lower(at) >= v_row.tracking_paused_at;
    END IF;

    RETURN v_row;
END;
$function$;
```

- [ ] **Step 3: Generate and apply the migration**

```bash
cd /Users/kris.braun/code/plot
psql "$DATABASE_URL" -tAc "show port;"        # sanity-check the target DB
pnpm gen-migration -- add_dismissed_focus_suggestions
pnpm apply-migrations                         # also regenerates libs/db/src/types.ts
pnpm diff-schema-migrations                   # expect: no differences
```

Expected: `gen-migration` writes a new file in `libs/db/migrations/` containing
`ALTER TABLE "user_settings" ADD COLUMN "dismissed_focus_suggestions"` and a
`CREATE OR REPLACE FUNCTION "user"."upsert_user_settings"`. `diff-schema-migrations`
prints no pending diff.

- [ ] **Step 4: Forward the field through the POST endpoint**

In `workers/api/src/app/sync/user-settings.ts`, add the new param to the
`rpcUser` call (after `p_tracking_paused_at`). `rpcUser` auto-serializes JS
arrays as `::jsonb`:

```ts
    return rpcUser(trx, "upsert_user_settings", {
      user_id: userId,
      p_enter_behavior: body.enter_behavior || null,
      p_onboarding_completed: body.onboarding_completed ?? null,
      // tracking_paused_at uses a sentinel epoch for explicit clear so an
      // omitted field stays "no change" rather than auto-resuming. The
      // function's CASE handles the sentinel; here we just forward null
      // when the client didn't send the field.
      p_tracking_paused_at: body.tracking_paused_at ?? null,
      // Union-merged server-side; null = no change.
      p_dismissed_focus_suggestions: body.dismissed_focus_suggestions ?? null,
    });
```

(The GET handler already `selectAll()`s `user_settings`, so the new column flows
to clients with no change.)

- [ ] **Step 5: Write the pgTAP test**

Create `libs/db/tests/60-user-settings-dismissed-suggestions.sql`:

```sql
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(5);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'dfs-60@example.test');
    -- Seed completion so we can prove it isn't clobbered later.
    PERFORM "user".upsert_user_settings(
        user_id => v_user,
        p_enter_behavior => NULL,
        p_onboarding_completed => true);
    CREATE TEMP TABLE _u (id uuid);
    INSERT INTO _u VALUES (v_user);
END $$;

-- 1. First dismissal records the key.
SELECT lives_ok($$
    SELECT "user".upsert_user_settings(
        user_id => (SELECT id FROM _u),
        p_enter_behavior => NULL,
        p_dismissed_focus_suggestions => '["project"]'::jsonb)
$$, 'first dismissal upsert succeeds');

SELECT ok(
    (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))
        @> '["project"]'::jsonb,
    'project key is recorded');

-- 2. A second, different key unions in (both present, deduped).
SELECT lives_ok($$
    SELECT "user".upsert_user_settings(
        user_id => (SELECT id FROM _u),
        p_enter_behavior => NULL,
        p_dismissed_focus_suggestions => '["customers","project"]'::jsonb)
$$, 'second dismissal upsert succeeds');

SELECT ok(
    (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))
        @> '["project","customers"]'::jsonb
    AND jsonb_array_length(
        (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))) = 2,
    'union merges both keys with no duplicates');

-- 3. Omitting the field (NULL) leaves dismissals AND onboarding intact.
SELECT ok(
    (SELECT onboarding_completed FROM user_settings WHERE user_id = (SELECT id FROM _u)) = true
    AND jsonb_array_length(
        (SELECT dismissed_focus_suggestions FROM user_settings WHERE user_id = (SELECT id FROM _u))) = 2,
    'a NULL dismissed payload changes neither the set nor onboarding_completed');

SELECT * FROM finish();
ROLLBACK;
```

- [ ] **Step 6: Run the pgTAP test**

```bash
cd /Users/kris.braun/code/plot/libs/db
pg_prove -d "$DATABASE_URL" tests/60-user-settings-dismissed-suggestions.sql
```

Expected: `tests/60-...sql .. ok` / `All tests successful.`

- [ ] **Step 7: Verify worker type-check**

```bash
cd /Users/kris.braun/code/plot && pnpm --filter @plotday/api exec tsc --noEmit
```

Expected: no errors. (`libs/db/src/types.ts` was regenerated in Step 3, so the
new optional param is in the typed `upsert_user_settings` Args.)

- [ ] **Step 8: Commit**

```bash
cd /Users/kris.braun/code/plot
git add libs/db/schema libs/db/migrations libs/db/src/types.ts libs/db/tests workers/api/src/app/sync/user-settings.ts
git commit -m "Add dismissed_focus_suggestions to user_settings (union-merged sync)"
```

---

## Task 2: Flutter — `StringListConverter`

**Files:**
- Create: `apps/plot/lib/util/string_list_converter.dart`
- Test: `apps/plot/test/util/string_list_converter_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/util/string_list_converter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/string_list_converter.dart';

void main() {
  const c = StringListConverter();

  test('SQL round-trip preserves order', () {
    expect(c.toSql(const ['project', 'customers']), 'project,customers');
    expect(c.fromSql('project,customers'), ['project', 'customers']);
  });

  test('empty string decodes to an empty list', () {
    expect(c.fromSql(''), isEmpty);
    expect(c.toSql(const []), '');
  });

  test('JSON (sync) round-trip uses a list of strings', () {
    expect(c.toJson(const ['project']), ['project']);
    expect(c.fromJson(<dynamic>['project', 'customers']),
        ['project', 'customers']);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter test test/util/string_list_converter_test.dart
```

Expected: FAIL — `Target of URI doesn't exist: 'package:plot/util/string_list_converter.dart'`.

- [ ] **Step 3: Implement the converter**

Create `apps/plot/lib/util/string_list_converter.dart`:

```dart
import 'package:drift/drift.dart';

/// Stores a `List<String>` as a comma-joined string in SQLite and as a JSON
/// array over the sync wire (matching the server's jsonb array columns).
/// Mirrors [UuidListConverter] in `uuid.dart`. Values must not contain commas;
/// the only use is stable identifier keys (focus-suggestion keys), which never
/// do.
class StringListConverter extends TypeConverter<List<String>, String>
    with JsonTypeConverter2<List<String>, String, List<dynamic>> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    return fromDb.split(',');
  }

  @override
  String toSql(List<String> value) => value.join(',');

  @override
  List<String> fromJson(List<dynamic> json) =>
      json.map((e) => e as String).toList();

  @override
  List<dynamic> toJson(List<String> value) => value;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter test test/util/string_list_converter_test.dart
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/util/string_list_converter.dart apps/plot/test/util/string_list_converter_test.dart
git commit -m "Add StringListConverter for jsonb-array Drift columns"
```

---

## Task 3: Flutter store — `dismissedFocusSuggestions` column + migration

**Files:**
- Modify: `apps/plot/lib/store/user_settings.dart:1-19`
- Modify: `apps/plot/lib/store/store.dart:2431` (schemaVersion) and the
  `onUpgrade` tail (~3909)

- [ ] **Step 1: Add the column to the Drift table**

In `apps/plot/lib/store/user_settings.dart`, add an import at the top (after the
`part of` line is not allowed — this is a `part`, so the import must already be in
`store.dart`). Instead, add the import in `apps/plot/lib/store/store.dart` with
the other imports:

```dart
import 'package:plot/util/string_list_converter.dart';
```

Then in `user_settings.dart`, add the column after `onboardingCompleted`:

```dart
  BoolColumn get onboardingCompleted => boolean().nullable()();

  /// Stable keys of the curated focus suggestions the user has created a focus
  /// from. Hides those suggestions in the "Add a focus" picker. Synced; the
  /// server union-merges so dismissals are monotonic across devices.
  TextColumn get dismissedFocusSuggestions =>
      text().nullable().map(const StringListConverter())();
```

- [ ] **Step 2: Bump the schema version**

In `apps/plot/lib/store/store.dart`, change line 2431:

```dart
  int get schemaVersion => 364;
```

- [ ] **Step 3: Add the migration step**

In `apps/plot/lib/store/store.dart`, in `Store.migration.onUpgrade`, add after the
`if (from < 363) { ... }` block (the current tail, ~line 3909):

```dart
    if (from < 364) {
      // Cross-device record of which focus suggestions the user has created a
      // focus from. Nullable; existing rows get NULL (= none dismissed).
      await _safeAddColumn(
        m,
        userSettings,
        userSettings.dismissedFocusSuggestions,
      );
    }
```

- [ ] **Step 4: Regenerate Drift code**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: completes; `store.g.dart` now references
`$converterdismissedFocusSuggestions` and the `dismissedFocusSuggestions`
getter on `UserSettingsRow`/`UserSettingsCompanion`.

- [ ] **Step 5: Verify it analyzes**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/store/user_settings.dart lib/store/store.dart
```

Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/store/user_settings.dart apps/plot/lib/store/store.dart apps/plot/lib/store/store.g.dart
git commit -m "Store: add dismissedFocusSuggestions column to user_settings (v364)"
```

---

## Task 4: Flutter — suggestion data file (`focus_suggestions.dart`) + delete dead onboarding chips

**Files:**
- Create: `apps/plot/lib/command/focus_suggestions.dart`
- Modify: `apps/plot/lib/command/priority.dart` (remove the `FocusPrefill` class
  at lines 554-578; add an import)
- Delete: `apps/plot/lib/widget/onboarding/onboarding_roles.dart`
- Modify: `apps/plot/lib/widget/onboarding/onboarding_steps.dart:5` (remove import)
- Test: `apps/plot/test/command/focus_suggestions_test.dart`

> This task also adds `mergeDismissed`, `visibleFocusSuggestions`, and
> `DismissedFocusSuggestions` to the new file (used by Task 5/6), so the new file
> lands once, fully formed.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/focus_suggestions_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/focus_suggestions.dart';

void main() {
  test('every suggestion has a non-empty key and the keys are unique', () {
    final keys = kFocusSuggestions.map((s) => s.suggestionKey).toList();
    for (final k in keys) {
      expect(k, isNotNull);
      expect(k, isNotEmpty);
    }
    expect(keys.toSet().length, keys.length, reason: 'keys must be unique');
  });

  test('visibleFocusSuggestions filters out dismissed keys, keeps order', () {
    final firstKey = kFocusSuggestions.first.suggestionKey!;
    final visible = visibleFocusSuggestions({firstKey});
    expect(visible.length, kFocusSuggestions.length - 1);
    expect(visible.any((s) => s.suggestionKey == firstKey), isFalse);
    // Order of the survivors matches the source order.
    expect(
      visible.map((s) => s.suggestionKey),
      kFocusSuggestions
          .where((s) => s.suggestionKey != firstKey)
          .map((s) => s.suggestionKey),
    );
  });

  test('visibleFocusSuggestions with no dismissals returns all', () {
    expect(visibleFocusSuggestions(const {}).length, kFocusSuggestions.length);
  });

  test('mergeDismissed appends a new key, preserving order', () {
    expect(mergeDismissed(const ['project'], 'customers'),
        ['project', 'customers']);
  });

  test('mergeDismissed is idempotent for an existing key', () {
    final existing = const ['project'];
    expect(identical(mergeDismissed(existing, 'project'), existing), isTrue);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter test test/command/focus_suggestions_test.dart
```

Expected: FAIL — `Target of URI doesn't exist: 'package:plot/command/focus_suggestions.dart'`.

- [ ] **Step 3: Create the suggestions file**

Create `apps/plot/lib/command/focus_suggestions.dart`. The list values are copied
verbatim from the (about-to-be-deleted) `onboarding_roles.dart`, with a stable
`suggestionKey` added to each:

```dart
import 'package:drift/drift.dart' show Value;

import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';

/// Pre-filled values for the focus create form. The "Add a focus" picker opens
/// the create modal with one of these populated so a suggestion is one tap from
/// an editable, ready-to-create focus. Onboarding's chips used to drive this;
/// the suggestions now live in the regular create flow.
class FocusPrefill {
  const FocusPrefill({
    required this.title,
    required this.description,
    required this.iconKey,
    this.color,
    this.suggestionKey,
  });

  /// Focus name pre-filled into the title field.
  final String title;

  /// Description pre-filled into the (required) description field. Transient —
  /// it feeds matching but isn't stored on the focus.
  final String description;

  /// Key into [PlotIcon.focusIcons] for the pre-selected icon.
  final String iconKey;

  /// Optional pre-selected colour. Null seeds the picker with the default
  /// colour.
  final ThemeColor? color;

  /// Stable identifier for a curated suggestion. When a focus is created from a
  /// prefill that carries this, the key is recorded in
  /// [DismissedFocusSuggestions] so the suggestion stops appearing. Null for
  /// the custom/empty create path.
  final String? suggestionKey;
}

/// Curated focus suggestions shown in the "Add a focus" picker.
///
/// Maintaining this list:
///  * Add an item → append with a fresh unique [FocusPrefill.suggestionKey];
///    it appears for everyone (no one has dismissed a brand-new key).
///  * Remove an item → delete the entry; any stored dismissal of its key
///    becomes a harmless orphan (filtering ignores unknown keys).
///  * Never reuse a key for a different concept — it would inherit the old
///    item's dismissals.
const List<FocusPrefill> kFocusSuggestions = [
  FocusPrefill(
    suggestionKey: 'project',
    title: 'Project',
    description: "Tasks, docs, and discussions for a project",
    iconKey: 'rocket',
    color: ThemeColor(0),
  ),
  FocusPrefill(
    suggestionKey: 'customers',
    title: 'Customers',
    description:
        'Supporting current customers and developing prospective customers',
    iconKey: 'handshake',
    color: ThemeColor(5),
  ),
  FocusPrefill(
    suggestionKey: 'operations',
    title: 'Operations',
    description: 'Maintaining processes and systems',
    iconKey: 'conveyorBelt',
    color: ThemeColor(1),
  ),
  FocusPrefill(
    suggestionKey: 'management',
    title: 'Management',
    description: 'One-on-ones, updates, and the people you manage',
    iconKey: 'userGroup',
    color: ThemeColor(2),
  ),
  FocusPrefill(
    suggestionKey: 'recruiting',
    title: 'Recruiting',
    description: 'Candidates, interviews, and your hiring pipeline',
    iconKey: 'userMagnifyingGlass',
    color: ThemeColor(5),
  ),
  FocusPrefill(
    suggestionKey: 'admin',
    title: 'Admin',
    description: 'HR, expenses, and administrative tasks',
    iconKey: 'receipt',
    color: ThemeColor(7),
  ),
  FocusPrefill(
    suggestionKey: 'reading',
    title: 'Reading',
    description: 'Articles, newsletters, and other long-form content',
    iconKey: 'bookOpen',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'volunteering',
    title: 'Volunteering',
    description: 'Everything related to a volunteer role',
    iconKey: 'handHoldingHeart',
    color: ThemeColor(4),
  ),
  FocusPrefill(
    suggestionKey: 'personal_admin',
    title: 'Personal admin',
    description: 'Errands, appointments, and personal to-dos',
    iconKey: 'house',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'social',
    title: 'Social',
    description: 'Friends and events',
    iconKey: 'balloons',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'promotions',
    title: 'Promotions',
    description: 'Offers and updates from brands you follow',
    iconKey: 'billboard',
    color: ThemeColor(6),
  ),
];

/// The suggestions still worth offering: every [kFocusSuggestions] entry whose
/// key is not in [dismissed], in source order.
List<FocusPrefill> visibleFocusSuggestions(Set<String> dismissed) =>
    kFocusSuggestions
        .where((s) => !dismissed.contains(s.suggestionKey))
        .toList();

/// Pure: append [key] to [existing] unless already present, preserving order.
/// Returns the same instance when nothing changes (lets callers skip a write).
List<String> mergeDismissed(List<String> existing, String key) {
  if (existing.contains(key)) return existing;
  return [...existing, key];
}

/// Cross-device record of the focus suggestions the user has acted on. Backed
/// by `user_settings.dismissed_focus_suggestions` (synced; union-merged
/// server-side).
class DismissedFocusSuggestions {
  const DismissedFocusSuggestions._();

  /// The dismissed suggestion keys. Empty when no settings row exists yet.
  static Future<Set<String>> get() async {
    final row = await UserSettingsEntity.get();
    return (row?.dismissedFocusSuggestions ?? const <String>[]).toSet();
  }

  /// Records [key] as dismissed (idempotent). No-op when already present, so a
  /// re-created suggestion doesn't churn the sync row.
  static Future<void> add(String key) async {
    final row = await UserSettingsEntity.get();
    final existing = row?.dismissedFocusSuggestions ?? const <String>[];
    final merged = mergeDismissed(existing, key);
    if (identical(merged, existing)) return;
    // Only this column is set; Store.save's DoUpdate updates present columns
    // only, so other settings (onboarding_completed, etc.) are preserved.
    await UserSettingsEntity.save(
      UserSettingsCompanion(dismissedFocusSuggestions: Value(merged)),
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter test test/command/focus_suggestions_test.dart
```

Expected: PASS (5 tests).

- [ ] **Step 5: Remove the old `FocusPrefill` from `priority.dart` and import the new file**

In `apps/plot/lib/command/priority.dart`:

1. Delete the entire `FocusPrefill` class and its doc comment (lines 554-578,
   from `/// Pre-filled values for the [NewFocus] step-1 form.` through the
   closing `}` of the class).
2. Add an import alongside the other `package:plot/...` imports near the top:

```dart
import 'package:plot/command/focus_suggestions.dart';
```

- [ ] **Step 6: Delete the dead onboarding chips and import**

```bash
cd /Users/kris.braun/code/plot
git rm apps/plot/lib/widget/onboarding/onboarding_roles.dart
```

In `apps/plot/lib/widget/onboarding/onboarding_steps.dart`, delete line 5:

```dart
import 'package:plot/widget/onboarding/onboarding_roles.dart';
```

- [ ] **Step 7: Verify nothing else referenced the deleted symbols**

```bash
cd /Users/kris.braun/code/plot/apps/plot && grep -rn "OnboardingRoles\|kSampleFocuses\|onboarding_roles" lib/ test/
```

Expected: no output (all references removed). `FocusPrefill` is now only
referenced from `priority.dart` and `focus_suggestions.dart`:

```bash
grep -rln "FocusPrefill" lib/ test/
```

Expected: `lib/command/focus_suggestions.dart`, `lib/command/priority.dart`,
`test/command/focus_suggestions_test.dart`.

- [ ] **Step 8: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/command/priority.dart lib/command/focus_suggestions.dart lib/widget/onboarding/onboarding_steps.dart
```

Expected: no new errors.

- [ ] **Step 9: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/focus_suggestions.dart apps/plot/lib/command/priority.dart apps/plot/lib/widget/onboarding/onboarding_steps.dart apps/plot/test/command/focus_suggestions_test.dart
git rm --cached apps/plot/lib/widget/onboarding/onboarding_roles.dart 2>/dev/null || true
git commit -m "Move focus suggestions to a dedicated file with stable keys; remove dead onboarding chips"
```

---

## Task 5: Flutter — thread `suggestionKey` through the create flow and record on save

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` — `AddPriority`,
  `_buildFocusDetailsForm`, `_FindMatchingThreads`, `_ShowFocusMatches`,
  `_buildFocusMatchesForm`, `_CreateFocusWithThreads`.

> No new automated test here (recording requires a live Store + signed-in user;
> covered by run-app in Task 7). The `mergeDismissed` logic it relies on is
> already tested in Task 4. Keep the edits mechanical.

- [ ] **Step 1: Add `suggestionKey` to `AddPriority` and record on save**

In `apps/plot/lib/command/priority.dart`, update `AddPriority` (currently
lines 311-342):

```dart
class AddPriority extends Command {
  AddPriority(this._priority, {this.suggestionKey})
    : super(
        title: 'Create focus',
        icon: PlotIcon.save,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;

  /// When this focus was created from a curated suggestion, its key — recorded
  /// as dismissed once the save succeeds so the suggestion stops appearing.
  final String? suggestionKey;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    final savedPriority = await priority.save();
    if (suggestionKey != null) {
      await DismissedFocusSuggestions.add(suggestionKey!);
    }
    final multi = context.mounted ? context.isMultiPanel : false;
    if (context.mounted) {
      final tabsRouter = _tabsRouterOrNull(context);
      PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: tabsRouter?.activeIndex,
        currentSourceTab: PrioritiesShell.sourceTab,
      );
    }
    return CommandRoute(
      PriorityRoute(
        priorityIdString: savedPriority.id.toShortString(),
        children: multi ? [NewThreadRoute()] : null,
      ),
      replace: true,
    );
  }
}
```

- [ ] **Step 2: Capture the key in the step-1 form and pass it to the buttons**

In `_buildFocusDetailsForm` (currently lines 633-705), capture the key once and
pass it into all three button commands. Replace the function body's `return
FormData(...)` button section so the buttons read:

At the top of the function body, just before `return FormData(`:

```dart
  final suggestionKey = prefill?.suggestionKey;
```

Then update the buttons:

```dart
          if (skipMatching)
            FormButton(
              key: 'create',
              isPrimary: true,
              buildCommand: (values) => AddPriority(
                Future.value(_priorityFromValues(values, root)),
                suggestionKey: suggestionKey,
              ),
            )
          else ...[
            FormButton(
              key: 'find',
              isPrimary: true,
              buildCommand: (values) => _FindMatchingThreads(
                values: values,
                root: root,
                suggestionKey: suggestionKey,
              ),
            ),
            FormButton(
              key: 'create',
              isPrimary: false,
              buildCommand: (values) => _CreateFocusWithThreads(
                values: values,
                root: root,
                matches: const [],
                selections: const {},
                suggestionKey: suggestionKey,
              ),
            ),
          ],
```

- [ ] **Step 3: Thread the key through the matching branch**

Update `_FindMatchingThreads` (lines 713-759): add the field and forward it.

```dart
class _FindMatchingThreads extends Command {
  _FindMatchingThreads({
    required this.values,
    required this.root,
    this.suggestionKey,
  }) : super(
        title: 'Find matching threads',
        icon: PlotIcon.search,
        eventObject: EventObject.modal,
        eventAction: EventAction.opened,
      );

  final Map<String, dynamic> values;
  final Priority root;
  final String? suggestionKey;
```

…and in its `run`, the final return becomes:

```dart
    if (!context.mounted) return const CommandSkipped();
    return _ShowFocusMatches(
      values: values,
      root: root,
      matches: matches,
      suggestionKey: suggestionKey,
    ).run(context);
```

Update `_ShowFocusMatches` (lines 771-786):

```dart
class _ShowFocusMatches extends ShowForm {
  _ShowFocusMatches({
    required Map<String, dynamic> values,
    required Priority root,
    required List<_FocusMatch> matches,
    String? suggestionKey,
  }) : super(
         title: 'Add a focus',
         icon: PlotIcon.add,
         form: (ctx) => _buildFocusMatchesForm(
           ctx,
           values: values,
           root: root,
           matches: matches,
           suggestionKey: suggestionKey,
         ),
       );
}
```

Update `_buildFocusMatchesForm` (lines 788-834): add the param and pass it to the
create button.

```dart
Future<FormData> _buildFocusMatchesForm(
  BuildContext context, {
  required Map<String, dynamic> values,
  required Priority root,
  required List<_FocusMatch> matches,
  String? suggestionKey,
}) async {
```

…and its create `FormButton`:

```dart
          FormButton(
            key: 'create',
            isPrimary: true,
            buildCommand: (selections) => _CreateFocusWithThreads(
              values: values,
              root: root,
              matches: matches,
              selections: selections,
              suggestionKey: suggestionKey,
            ),
          ),
```

- [ ] **Step 4: Record on save in `_CreateFocusWithThreads`**

Update `_CreateFocusWithThreads` (lines 838-907): add the field and record after
the focus is saved.

```dart
class _CreateFocusWithThreads extends Command {
  _CreateFocusWithThreads({
    required this.values,
    required this.root,
    required this.matches,
    required this.selections,
    this.suggestionKey,
  }) : super(
         title: 'Create focus',
         icon: PlotIcon.save,
         eventObject: EventObject.priority,
         eventAction: EventAction.added,
       );

  final Map<String, dynamic> values;
  final Priority root;
  final List<_FocusMatch> matches;
  final Map<String, dynamic> selections;
  final String? suggestionKey;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final focus = await _priorityFromValues(values, root).save();

    if (suggestionKey != null) {
      await DismissedFocusSuggestions.add(suggestionKey!);
    }

    // ...rest of the existing method body is unchanged...
```

(Leave the rest of `run` — the selected/deselected handling and the trailing
`ChangeCurrentPriority(focus).run(context)` — exactly as is.)

- [ ] **Step 5: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/command/priority.dart
```

Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/priority.dart
git commit -m "Record focus-suggestion dismissal when a focus is created from a prefill"
```

---

## Task 6: Flutter — `AddFocus` picker command + wire entry points

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` — add `AddFocus`,
  `_CreateCustomFocus`, `_CreateSuggestedFocus`.
- Modify: `apps/plot/lib/widget/priorities_list.dart:117-121`
- Modify: `apps/plot/lib/command/global.dart:102`
- Modify: `apps/plot/lib/command/priority.dart:236` (focus-switcher secondary)

- [ ] **Step 1: Add the `AddFocus` command and its row commands**

In `apps/plot/lib/command/priority.dart`, add after the `NewFocus` class
(after line 622). `ShowCommands`, `Commands`, and `StaticCommandGroup` come from
the existing `command.dart`/`command/base.dart` imports already in this file.

```dart
/// Entry point for "Add a focus". Loads the user's dismissed-suggestion set,
/// then either opens a picker (custom focus + remaining curated suggestions) or,
/// when no suggestions remain, opens the create form directly. Picking a
/// suggestion prefills the same two-step [NewFocus] form; creating from it
/// records the dismissal (see [DismissedFocusSuggestions]).
class AddFocus extends Command {
  AddFocus()
    : super(
        title: 'Add a focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final dismissed = await DismissedFocusSuggestions.get();
    final suggestions = visibleFocusSuggestions(dismissed);
    if (!context.mounted) return const CommandSkipped();

    // Nothing left to suggest — the picker would show only "Create a custom
    // focus", so skip straight to the create form.
    if (suggestions.isEmpty) {
      return NewFocus().run(context);
    }

    return ShowCommands(
      title: 'Add a focus',
      icon: PlotIcon.add,
      commands: Commands(
        groups: [
          StaticCommandGroup(commands: [_CreateCustomFocus()]),
          StaticCommandGroup(
            title: 'Suggestions',
            commands: [
              for (final s in suggestions) _CreateSuggestedFocus(s),
            ],
          ),
        ],
      ),
    ).run(context);
  }
}

/// "Create a custom focus" row — opens the empty two-step create form.
class _CreateCustomFocus extends Command {
  _CreateCustomFocus()
    : super(
        title: 'Create a custom focus',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  @override
  Future<CommandReturn> run(BuildContext context) => NewFocus().run(context);
}

/// A curated-suggestion row — opens the two-step create form prefilled.
class _CreateSuggestedFocus extends Command {
  _CreateSuggestedFocus(this.suggestion)
    : super(
        title: suggestion.title,
        subtitle: suggestion.description,
        icon: PlotIcon.focusIcon(suggestion.iconKey),
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final FocusPrefill suggestion;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      NewFocus(prefill: suggestion).run(context);
}
```

- [ ] **Step 2: Wire the sidebar button**

In `apps/plot/lib/widget/priorities_list.dart`, change the `CommandWrapper`
target (line 118) from `NewFocus()` to `AddFocus()`:

```dart
                ListTile(
                  command: CommandWrapper(
                    AddFocus(),
                    icon: Value(null),
                    title: 'Add a focus',
                  ),
```

(`AddFocus` is in `priority.dart`, already imported by this widget via the
command barrel; if `flutter analyze` reports it undefined, add
`import 'package:plot/command/priority.dart';`.)

- [ ] **Step 3: Wire the global command palette**

In `apps/plot/lib/command/global.dart`, change line 102:

```dart
        commands: [PickCurrentPriority(), AddFocus()],
```

- [ ] **Step 4: Wire the focus-switcher secondary action**

In `apps/plot/lib/command/priority.dart`, change `ChangeCurrentPriorityCommands`
(line 236):

```dart
class ChangeCurrentPriorityCommands extends Commands {
  ChangeCurrentPriorityCommands({Priority? initialPriority})
    : super(
        groups: [_FocusSwitchGroup()],
        secondaryCommand: (prompt) => AddFocus(),
      );
}
```

(Focuses are flat — filed under root — so the dropped `parent: initialPriority`
was already moot for creation.)

- [ ] **Step 5: Analyze the touched files**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze lib/command/priority.dart lib/command/global.dart lib/widget/priorities_list.dart
```

Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/priority.dart apps/plot/lib/command/global.dart apps/plot/lib/widget/priorities_list.dart
git commit -m "Add focus-suggestion picker (AddFocus) and route Add-a-focus through it"
```

---

## Task 7: Verification, docs, finalize

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Full Flutter analyze and test**

```bash
cd /Users/kris.braun/code/plot/apps/plot && flutter analyze
cd /Users/kris.braun/code/plot/apps/plot && flutter test test/util/string_list_converter_test.dart test/command/focus_suggestions_test.dart
```

Expected: analyze reports no new issues; both test files pass.

- [ ] **Step 2: DB sync + lint checks**

```bash
cd /Users/kris.braun/code/plot
pnpm diff-schema-migrations           # expect: no differences
pnpm --filter @plotday/db run lint    # expect: types in sync
```

- [ ] **Step 3: Add the user-facing update note**

In `docs/updates.md`, add a bullet to the top (most-recent) section:

```markdown
- When you add a focus, Plot now suggests common focuses (like Customers, Reading, or Social) you can create with one tap — and tucks away each suggestion once you've used it.
```

- [ ] **Step 4: run-app smoke test (manual)**

Use the `run-app` skill, then verify:
1. Sidebar "Add a focus" → picker opens with "Create a custom focus" on top and a
   "Suggestions" section (icon + title + description per row).
2. Pick a suggestion → the two-step create form opens prefilled (name, icon,
   color, description). Complete it → focus is created.
3. Re-open "Add a focus" → that suggestion is gone from the list.
4. "Create a custom focus" → empty two-step form.
5. (Optional) Dismiss all suggestions → "Add a focus" opens the create form
   directly (no picker).

Confirm no runtime errors via `mcp__dart-mcp__get_runtime_errors`.

- [ ] **Step 5: Commit docs and finalize**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs: note focus suggestions in Add a focus"
```

Then run the `/finalize` checklist (lint, backwards-compat, error capture, docs,
public submodule) before declaring complete.

---

## Self-review notes

- **Spec coverage:** suggestion list relocated w/ stable keys (Task 4); picker
  with custom + suggestions incl. description subtitle (Task 6); all-dismissed
  shortcut (Task 6 Step 1); prefill via existing two-step form (Task 6); cross-
  device storage (Tasks 1, 3); record-only-on-save (Task 5); three entry points
  (Task 6); onboarding chips removed (Task 4). All covered.
- **Backwards compat:** new column is nullable/defaulted; older clients omit the
  field (server treats null as no-change); GET `selectAll` surfaces it
  automatically. Expand-only migration (additive), safe for the deploy window.
- **Type consistency:** `suggestionKey` (FocusPrefill field), `kFocusSuggestions`,
  `visibleFocusSuggestions`, `mergeDismissed`, `DismissedFocusSuggestions.get/add`,
  `dismissedFocusSuggestions` (Drift column + row/companion),
  `p_dismissed_focus_suggestions` (RPC) — names used consistently across tasks.
- **Error capture:** no new `catch` blocks added (the create commands' existing
  `try/catch` with `Tracker.captureException` are untouched). `DismissedFocusSuggestions.add`
  lets store/sync errors propagate per the repo's "never fire-and-forget" rule;
  if a try/catch is later added around the `add()` call, it must call
  `Tracker.captureException`.
