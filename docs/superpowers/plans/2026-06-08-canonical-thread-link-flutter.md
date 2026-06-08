# Canonical Thread Link + Status Icons — Flutter UI (Plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the already-shipped data layer (Plan 1 server/SDK + Plan 2 connectors) in the Flutter client so a thread shows exactly ONE external link's status (the primary by `priority`), with the status icon in the page header and on the feed row, an "Open in [Connector]" menu command, and no per-link header rows.

**Architecture:** The `link` table already carries connector-supplied `priority` (int) and `note_scoped` (bool), and each `LinkStatus` carries a curated `icon` (`StatusIcon`) + optional `hiddenDefault`, all reaching Flutter via `user.link` sync and `LinkTypeConfig.statuses`. This plan (1) syncs the two new `link` columns into the Drift model, (2) parses `icon`/`hiddenDefault` into the local `LinkStatus`, (3) defines ONE `Thread.primaryLink` helper (highest-priority non-archived canonical link, tie-broken by earliest `created_at`) and routes the existing inconsistent primary-link logic through it, (4) makes `Link.watchForThread` canonical-only and deterministically ordered, and (5) renders a single status icon (header + feed row) and an "Open in [Connector]" command, removing the old per-link header rows and the tag-based status glyph.

**Tech Stack:** Flutter, Drift (SQLite local store), flutter_bloc, forui, font_awesome_flutter. Tests use `flutter_test` with `Store.forTesting(NativeDatabase.memory())`.

---

## Background the implementer needs

**What Plan 1/2 already deliver (do NOT re-implement):**

- `link` table (server) has two new columns, both in `user.link` so they sync to Flutter:
  - `priority integer NOT NULL DEFAULT 0` — connector-supplied primary-link ranking.
  - `note_scoped boolean NOT NULL DEFAULT false` — TRUE when the link is attached to a note (`note.link_id`), not the thread. Note-scoped links (e.g. Granola meeting notes) are **excluded from thread-level surfacing and primary-link selection**.
- The authoritative primary-link definition (from `libs/db/schema/50-tables/25-link.sql`): *"the highest-priority non-archived canonical (note_scoped = false) link as the thread's single external link; ties break on earliest created_at. Default 0."*
- The SDK `LinkStatus` (twister `public/twister/src/tools/integrations.ts`) now has a **required** `icon: StatusIcon` and an optional `hiddenDefault?: boolean`. `StatusIcon` is exactly these 8 string values: `backlog`, `todo`, `inProgress`, `blocked`, `done`, `cancelled`, `confirmed`, `tentative`. `hiddenDefault: true` means "suppress on the feed row but still show in the page header" (used by Google Calendar's `Confirmed`).
- Connector status metadata reaches Flutter as JSON on `LinkTypeConfig.statuses` (the same path `Link.statusLabel` reads today). JSON keys arrive **camelCase** (`icon`, `hiddenDefault`) — but follow the existing convention of also accepting snake_case fallbacks (`hidden_default`) for safety, matching every other field in `LinkTypeConfig.fromJson`.

**Key local-store facts:**

- The local `links` table has **no `archived_at`**. Connector removals arrive as `revoked` tombstones that are hard-deleted on pull, so every present row is live. "Non-archived canonical link" therefore reduces to "present row with `note_scoped = false`".
- Note-attached links render inline on their own note via a **separate path** (the note's own link rendering), NOT via `Link.watchForThread`. Filtering `watchForThread` to `note_scoped = false` does not affect note-link rendering — it only removes note-scoped links from thread-level consumers. **Surfacing note-scoped links inline is out of scope for this plan** (Plan 1/2 territory; unchanged here).
- `Store.schemaVersion` is currently **361** (last migration step `if (from < 361)` in `lib/store/store.dart`). The next version is **362**.
- Web font cache-busting: `apps/plot/scripts/cache-bust-fonts.sh` has `FONT_CACHE_VERSION=19`. Adding any new `FontAwesomeIcons.*` glyph requires bumping it (→ 20).

**Conventions (from project guidelines) — apply throughout:**

- **Desktop cursor:** do NOT add `SystemMouseCursors.click` to buttons / status icons / menu items. The status icon and menu items are normal tap targets (default arrow). The pointer cursor is reserved for true external-URL link rows — and those rows are being removed.
- **`dart:io` `Platform.isX` throws on web** — gate any such access with `kIsWeb`. (None expected in this plan, but watch for it.)
- **Do NOT `dart format`** — match surrounding style by hand (the repo uses an old short style).
- **forui only:** import only `flutter/widgets.dart` and `forui/forui.dart`, never `flutter/material.dart`.
- **Modals:** use the project's `SelectModal` (already used by the status picker) — never `showDialog`/`FDialog`.
- After editing Drift `store/*` models, regenerate codegen: `cd apps/plot && flutter pub run build_runner build` (the generated `*.g.dart` is gitignored — do not commit it).
- Run `flutter analyze` from `apps/plot` after each task; 0 new issues.

**Worktree:** This plan executes in the `canonical-thread-link-flutter` worktree (branched from local `main`, which has Plan 1/2). `flutter pub get` has been run. No worktree DB is needed (Flutter-only; the migration is a local Drift schema-version bump, not a Postgres migration).

---

## File map

| File | Responsibility | Change |
| --- | --- | --- |
| `apps/plot/lib/store/link.dart` | `Links` Drift table, `Link`, `LinkTypeConfig`, `LinkStatus`, `StatusIcon` | Add `priority`/`noteScoped` columns + getters (T1); add `StatusIcon` enum + parse `icon`/`hiddenDefault` (T2); glyph mapping (T3); canonical filter + order on `watchForThread` (T5) |
| `apps/plot/lib/store/store.dart` | Drift schema version + `onUpgrade` migrations | Add v362 migration step, bump `schemaVersion` (T1) |
| `apps/plot/lib/store/thread.dart` | `Thread` model + primary-link helpers | Add `Thread.primaryLink`; route `resolveSharingModel`/`isPlotThread`/`resolvePrimaryAssignmentLink` through it (T4) |
| `apps/plot/lib/state/thread_state.dart` | `ThreadState` | Route `primaryLinkTypeConfig` through `Thread.primaryLink` (T4) |
| `apps/plot/scripts/cache-bust-fonts.sh` | Web font cache version | Bump `FONT_CACHE_VERSION` 19→20 (T3) |
| `apps/plot/lib/widget/status_icon_button.dart` | **NEW** — status glyph button + status-change modal | Create (T6) |
| `apps/plot/lib/widget/primary_link_header_actions.dart` | **NEW** — header join-meeting button(s) + always-shown status icon, watching the primary canonical link | Create (T7) |
| `apps/plot/lib/page/thread.dart` | ThreadPage | Remove `_ThreadLinkRow` rows + the row/badge classes; drop "Connect your account"; add `PrimaryLinkHeaderActions` to `_ThreadActionsRow` (T7) |
| `apps/plot/lib/widget/unified_header.dart` | Single-panel header | Add `PrimaryLinkHeaderActions` to the thread `trailing` list (T7) |
| `apps/plot/lib/widget/thread.dart` | `ThreadCommands` feed-row trailing area | Add trailing status icon (suppress `hiddenDefault`) from the primary canonical link (T8) |
| `apps/plot/lib/command/open_thread_link.dart` | **NEW** — "Open in [Connector]" command | Create (T9) |
| `apps/plot/lib/command/thread.dart` | `threadCommands` / `threadCommandGroupsSync` / `threadCommandGroups` | Thread an `openInLink` param + emit `OpenThreadLink` (T9) |
| `apps/plot/lib/page/thread.dart` (menu call site) + `apps/plot/lib/widget/thread.dart` (row menu call site) | Pass the primary canonical link into the command builders (T9) |

Test files (created per task): `test/store/link_canonical_columns_test.dart`, `test/store/link_status_icon_test.dart`, `test/store/status_icon_glyph_test.dart`, `test/store/primary_link_test.dart`, `test/store/watch_for_thread_canonical_test.dart`, `test/command/open_thread_link_test.dart`.

---

## Task 1: Sync `priority` + `noteScoped` onto the local `Link` model

**Files:**
- Modify: `apps/plot/lib/store/link.dart` (`Links` table ~line 276; `Link` getters ~line 504)
- Modify: `apps/plot/lib/store/store.dart` (`onUpgrade` ~line 3884; `schemaVersion`)
- Test: `apps/plot/test/store/link_canonical_columns_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('priority and noteScoped round-trip through the links table', () async {
    final threadId = Uuid.generate();
    final linkId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(linkId),
            sourceCreatedAt: DateTime.now(),
            threadId: Value(threadId),
            priority: const Value(7),
            noteScoped: const Value(true),
          ),
        );

    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(linkId.toBytes())))
        .getSingle();
    final link = Link(row);

    expect(link.priority, 7);
    expect(link.noteScoped, isTrue);
  });

  test('priority defaults to 0 and noteScoped to false', () async {
    final linkId = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(linkId),
            sourceCreatedAt: DateTime.now(),
          ),
        );
    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(linkId.toBytes())))
        .getSingle();
    final link = Link(row);

    expect(link.priority, 0);
    expect(link.noteScoped, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/link_canonical_columns_test.dart`
Expected: FAIL — compile error, `LinksCompanion.insert` has no `priority`/`noteScoped` and `Link` has no `priority`/`noteScoped` getters.

- [ ] **Step 3: Add the Drift columns**

In `apps/plot/lib/store/link.dart`, inside `class Links` (after `mergedFromThreadId`, before `revoked` ~line 297), add:

```dart
  /// Connector-supplied primary-link ranking. The thread's single external
  /// link is the highest-priority non-archived canonical (note_scoped=false)
  /// link; ties break on earliest created_at. Mirrors `link.priority`.
  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// TRUE when this link is attached to a note (note.link_id), not the thread.
  /// Note-scoped links are excluded from thread-level surfacing and
  /// primary-link selection. Mirrors `link.note_scoped`.
  BoolColumn get noteScoped =>
      boolean().withDefault(const Constant(false))();
```

(The Drift SQL column names auto-derive to `priority` and `note_scoped`, matching the `user.link` JSON keys that `LinkRow.fromJson` consumes.)

- [ ] **Step 4: Add the `Link` getters**

In `apps/plot/lib/store/link.dart`, in `class Link`, after `String? get status => _link.status;` (~line 515) add:

```dart
  int get priority => _link.priority;
  bool get noteScoped => _link.noteScoped;
```

- [ ] **Step 5: Add the migration step and bump the schema version**

In `apps/plot/lib/store/store.dart`, at the END of the `onUpgrade` chain (after the last `if (from < 361) { ... }` block), add:

```dart
        if (from < 362) {
          await m.addColumn(links, links.priority);
          await m.addColumn(links, links.noteScoped);
        }
```

Then bump `schemaVersion` from `361` to `362` (search for `schemaVersion` near the top of `Store`).

- [ ] **Step 6: Regenerate Drift codegen**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: completes; `store.g.dart` (gitignored) now has `priority`/`noteScoped` on `LinkRow`/`LinksCompanion`.

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/link_canonical_columns_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 8: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/link.dart lib/store/store.dart test/store/link_canonical_columns_test.dart`
Expected: No new issues.

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/lib/store/store.dart apps/plot/test/store/link_canonical_columns_test.dart
git commit -m "feat(store): sync link.priority and link.note_scoped into Drift model"
```

---

## Task 2: Parse `icon` (StatusIcon) and `hiddenDefault` into `LinkStatus`

**Files:**
- Modify: `apps/plot/lib/store/link.dart` (`LinkStatus` ~line 207)
- Test: `apps/plot/test/store/link_status_icon_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('LinkStatus.fromJson icon + hiddenDefault', () {
    test('parses every StatusIcon value (camelCase keys)', () {
      for (final entry in {
        'backlog': StatusIcon.backlog,
        'todo': StatusIcon.todo,
        'inProgress': StatusIcon.inProgress,
        'blocked': StatusIcon.blocked,
        'done': StatusIcon.done,
        'cancelled': StatusIcon.cancelled,
        'confirmed': StatusIcon.confirmed,
        'tentative': StatusIcon.tentative,
      }.entries) {
        final s = LinkStatus.fromJson({
          'status': 'x',
          'label': 'X',
          'icon': entry.key,
        });
        expect(s.icon, entry.value, reason: entry.key);
      }
    });

    test('parses hiddenDefault (camelCase and snake_case)', () {
      expect(
        LinkStatus.fromJson({
          'status': 'confirmed',
          'label': 'Confirmed',
          'icon': 'confirmed',
          'hiddenDefault': true,
        }).hiddenDefault,
        isTrue,
      );
      expect(
        LinkStatus.fromJson({
          'status': 'confirmed',
          'label': 'Confirmed',
          'icon': 'confirmed',
          'hidden_default': true,
        }).hiddenDefault,
        isTrue,
      );
    });

    test('icon is null and hiddenDefault false when absent', () {
      final s = LinkStatus.fromJson({'status': 'open', 'label': 'Open'});
      expect(s.icon, isNull);
      expect(s.hiddenDefault, isFalse);
    });

    test('unknown icon string parses to null (forward-compat)', () {
      final s = LinkStatus.fromJson({
        'status': 'open',
        'label': 'Open',
        'icon': 'someFutureIcon',
      });
      expect(s.icon, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/link_status_icon_test.dart`
Expected: FAIL — `StatusIcon` undefined, `LinkStatus` has no `icon`/`hiddenDefault`.

- [ ] **Step 3: Add the `StatusIcon` enum**

In `apps/plot/lib/store/link.dart`, ABOVE `class LinkStatus` (~line 207), add:

```dart
/// Curated status-icon vocabulary. Mirrors `StatusIcon` in
/// `public/twister/src/tools/integrations.ts`. Connectors map each status to
/// one of these; the client renders a single glyph per value.
enum StatusIcon {
  backlog,
  todo,
  inProgress,
  blocked,
  done,
  cancelled,
  confirmed,
  tentative;

  /// Parse the SDK string form, or null for absent/unknown values (so an
  /// older cached config or a future icon never crashes the client).
  static StatusIcon? fromJson(String? value) => switch (value) {
        'backlog' => StatusIcon.backlog,
        'todo' => StatusIcon.todo,
        'inProgress' => StatusIcon.inProgress,
        'blocked' => StatusIcon.blocked,
        'done' => StatusIcon.done,
        'cancelled' => StatusIcon.cancelled,
        'confirmed' => StatusIcon.confirmed,
        'tentative' => StatusIcon.tentative,
        _ => null,
      };
}
```

- [ ] **Step 4: Add `icon` + `hiddenDefault` to `LinkStatus`**

In `class LinkStatus`, add the two fields, update the constructor and `fromJson`:

```dart
class LinkStatus {
  final String status;
  final String label;
  final int? tag;
  final StatusIcon? icon;
  final bool hiddenDefault;
  final bool done;
  final bool todo;

  const LinkStatus({
    required this.status,
    required this.label,
    this.tag,
    this.icon,
    this.hiddenDefault = false,
    this.done = false,
    this.todo = false,
  });

  factory LinkStatus.fromJson(Map<String, dynamic> json) {
    return LinkStatus(
      status: json['status'] as String,
      label: json['label'] as String,
      tag: json['tag'] as int?,
      icon: StatusIcon.fromJson(json['icon'] as String?),
      hiddenDefault: json['hiddenDefault'] as bool? ??
          json['hidden_default'] as bool? ??
          false,
      done: json['done'] as bool? ?? false,
      todo: json['todo'] as bool? ?? false,
    );
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/link_status_icon_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/link.dart test/store/link_status_icon_test.dart`
Expected: No new issues.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/test/store/link_status_icon_test.dart
git commit -m "feat(store): parse StatusIcon + hiddenDefault into LinkStatus"
```

---

## Task 3: Map `StatusIcon` → glyph

**Files:**
- Modify: `apps/plot/lib/store/link.dart` (add a getter on `StatusIcon`)
- Modify: `apps/plot/scripts/cache-bust-fonts.sh` (`FONT_CACHE_VERSION`)
- Test: `apps/plot/test/store/status_icon_glyph_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('every StatusIcon maps to a distinct, non-null glyph', () {
    final glyphs = StatusIcon.values.map((s) => s.glyph).toList();
    // All 8 present.
    expect(glyphs, hasLength(StatusIcon.values.length));
    // No nulls (the getter is non-nullable, this guards the switch is total).
    expect(glyphs.whereType<void>(), isEmpty);
    // Distinct glyphs so statuses are visually distinguishable.
    expect(glyphs.toSet(), hasLength(StatusIcon.values.length));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/status_icon_glyph_test.dart`
Expected: FAIL — `StatusIcon` has no `glyph`.

- [ ] **Step 3: Add the `glyph` getter**

`apps/plot/lib/store/link.dart` already imports nothing icon-related at the `StatusIcon` site; add the import at the TOP of the `part`'s parent? `link.dart` is `part of 'store.dart'`, so `font_awesome_flutter` must be imported by `store.dart`. Verify with `grep -n "font_awesome" lib/store/store.dart` — it is already imported there (used widely). Add to the `StatusIcon` enum:

```dart
  /// The glyph rendered for this status. Total over all values so the UI
  /// always has something to show (the SDK marks `icon` required).
  IconData get glyph => switch (this) {
        StatusIcon.backlog => FontAwesomeIcons.circleDashed,
        StatusIcon.todo => FontAwesomeIcons.circle,
        StatusIcon.inProgress => FontAwesomeIcons.circleHalfStroke,
        StatusIcon.blocked => FontAwesomeIcons.octagonXmark,
        StatusIcon.done => FontAwesomeIcons.circleCheck,
        StatusIcon.cancelled => FontAwesomeIcons.circleXmark,
        StatusIcon.confirmed => FontAwesomeIcons.calendarCheck,
        StatusIcon.tentative => FontAwesomeIcons.circleQuestion,
      };
```

`IconData`/`FontAwesomeIcons` resolve through `store.dart`'s existing imports (`package:flutter/widgets.dart` provides `IconData`; `font_awesome_flutter` provides the icons). If `flutter analyze` reports any of these glyphs as undefined, substitute the closest existing `FontAwesomeIcons.*` (the analyzer/compiler will catch a typo — `octagonXmark` and `circleHalfStroke` are already used elsewhere in the app, e.g. `lib/widget/icon.dart`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/status_icon_glyph_test.dart`
Expected: PASS.

- [ ] **Step 5: Bump the web font cache version**

In `apps/plot/scripts/cache-bust-fonts.sh`, change `FONT_CACHE_VERSION=19` to `FONT_CACHE_VERSION=20` (new FontAwesome glyphs change the tree-shaken web font; without this, web users get tofu boxes).

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/link.dart test/store/status_icon_glyph_test.dart`
Expected: No new issues.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/scripts/cache-bust-fonts.sh apps/plot/test/store/status_icon_glyph_test.dart
git commit -m "feat(store): map StatusIcon to glyphs; bump font cache version"
```

---

## Task 4: One consolidated `Thread.primaryLink` helper; route existing helpers through it

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (`resolveSharingModel` ~4775, `isPlotThread` ~4795, `resolvePrimaryAssignmentLink` ~4813)
- Modify: `apps/plot/lib/state/thread_state.dart` (`primaryLinkTypeConfig` ~69)
- Test: `apps/plot/test/store/primary_link_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<Link> insertLink({
    required int priority,
    required bool noteScoped,
    required DateTime createdAt,
  }) async {
    final id = Uuid.generate();
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(id),
            sourceCreatedAt: createdAt,
            createdAt: Value(createdAt),
            threadId: Value(Uuid.generate()),
            priority: Value(priority),
            noteScoped: Value(noteScoped),
          ),
        );
    final row = await (store.select(store.links)
          ..where((l) => l.id.equals(id.toBytes())))
        .getSingle();
    return Link(row);
  }

  test('returns null for empty and for all-note-scoped lists', () async {
    expect(Thread.primaryLink([]), isNull);
    final noteOnly = await insertLink(
      priority: 9,
      noteScoped: true,
      createdAt: DateTime(2026, 1, 1),
    );
    expect(Thread.primaryLink([noteOnly]), isNull);
  });

  test('highest priority wins, note-scoped excluded', () async {
    final low = await insertLink(
      priority: 1,
      noteScoped: false,
      createdAt: DateTime(2026, 1, 1),
    );
    final high = await insertLink(
      priority: 5,
      noteScoped: false,
      createdAt: DateTime(2026, 1, 2),
    );
    final highestButNoteScoped = await insertLink(
      priority: 99,
      noteScoped: true,
      createdAt: DateTime(2026, 1, 3),
    );
    final primary = Thread.primaryLink([low, high, highestButNoteScoped]);
    expect(primary!.id, high.id);
  });

  test('ties break on earliest created_at', () async {
    final later = await insertLink(
      priority: 3,
      noteScoped: false,
      createdAt: DateTime(2026, 2, 2),
    );
    final earlier = await insertLink(
      priority: 3,
      noteScoped: false,
      createdAt: DateTime(2026, 1, 1),
    );
    final primary = Thread.primaryLink([later, earlier]);
    expect(primary!.id, earlier.id);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/primary_link_test.dart`
Expected: FAIL — `Thread.primaryLink` undefined.

- [ ] **Step 3: Add `Thread.primaryLink` and route the helpers through it**

In `apps/plot/lib/store/thread.dart`, add the helper directly ABOVE `resolveSharingModel` (~line 4775):

```dart
  /// The thread's single canonical external link, or null when the thread has
  /// no canonical link (Plot-native, or only note-scoped links). Defined once
  /// here so every "primary link" consumer agrees:
  ///
  /// primary = the non-archived canonical (`note_scoped == false`) link with
  /// the highest [Link.priority], ties broken by earliest `created_at`
  /// (then link id for total determinism).
  ///
  /// The local `links` table has no `archived_at` — present rows are live
  /// (connector removals arrive as hard-deleted `revoked` tombstones), so
  /// "non-archived" reduces to "present and not note-scoped".
  static Link? primaryLink(List<Link> links) {
    final canonical = links.where((l) => !l.noteScoped).toList()
      ..sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority); // highest first
        if (byPriority != 0) return byPriority;
        final byCreated = a.createdAt.compareTo(b.createdAt); // earliest first
        if (byCreated != 0) return byCreated;
        return a.id.toString().compareTo(b.id.toString());
      });
    return canonical.isEmpty ? null : canonical.first;
  }
```

Then rewrite the three existing helpers to delegate:

```dart
  static SharingModel resolveSharingModel(List<Link> links) {
    final primary = primaryLink(links);
    return primary?.getTypeConfig()?.sharingModel ?? SharingModel.thread;
  }
```

```dart
  static bool isPlotThread(List<Link> links) {
    final primary = primaryLink(links);
    if (primary == null) return true;
    final creator = primary.createdBy;
    if (creator == null) return true;
    return !(TwistInstance.fromCache(creator)?.isSource ?? false);
  }
```

```dart
  /// The link whose assignee is shown in the thread row / header avatar slot,
  /// or null when the thread is not in "assignment mode". A thread is in
  /// assignment mode when its primary canonical link's [LinkTypeConfig] has
  /// BOTH `sharingModel == channel` AND `supportsAssignee == true`.
  static Link? resolvePrimaryAssignmentLink(List<Link> links) {
    final primary = primaryLink(links);
    if (primary == null) return null;
    final cfg = primary.getTypeConfig();
    if (cfg?.sharingModel == SharingModel.channel &&
        cfg?.supportsAssignee == true) {
      return primary;
    }
    return null;
  }
```

Keep the existing leading doc-comments on each helper (above their declarations); only the bodies/signatures change as shown. Delete the now-stale wording about "earliest-created link" / "sort by createdAt" in those comments and replace with "primary canonical link" phrasing.

- [ ] **Step 4: Route `ThreadState.primaryLinkTypeConfig`**

In `apps/plot/lib/state/thread_state.dart` (~line 66), replace:

```dart
  LinkTypeConfig? get primaryLinkTypeConfig =>
      links.isEmpty ? null : links.first.getTypeConfig();
```

with:

```dart
  /// LinkTypeConfig of the thread's primary canonical link (see
  /// [Thread.primaryLink]), used to adapt composer copy. Null when the thread
  /// has no canonical link or no resolvable type.
  LinkTypeConfig? get primaryLinkTypeConfig =>
      Thread.primaryLink(links)?.getTypeConfig();
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/primary_link_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the broader store/state suite for regressions**

Run: `cd apps/plot && flutter test test/store test/state`
Expected: PASS (no regressions in sharing-model / plot-thread / assignment tests).

- [ ] **Step 7: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart lib/state/thread_state.dart test/store/primary_link_test.dart`
Expected: No new issues.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/store/thread.dart apps/plot/lib/state/thread_state.dart apps/plot/test/store/primary_link_test.dart
git commit -m "refactor(store): consolidate primary-link selection into Thread.primaryLink"
```

---

## Task 5: `Link.watchForThread` — canonical filter + deterministic order

**Files:**
- Modify: `apps/plot/lib/store/link.dart` (`watchForThread` ~line 685)
- Test: `apps/plot/test/store/watch_for_thread_canonical_test.dart` (create)

- [ ] **Step 1: Write the failing test**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<void> insert(ThreadId threadId,
      {required int priority,
      required bool noteScoped,
      required DateTime createdAt}) async {
    await store.into(store.links).insert(
          LinksCompanion.insert(
            id: Value(Uuid.generate()),
            sourceCreatedAt: createdAt,
            createdAt: Value(createdAt),
            threadId: Value(threadId),
            priority: Value(priority),
            noteScoped: Value(noteScoped),
          ),
        );
  }

  test('excludes note-scoped links and orders by priority desc, created asc',
      () async {
    final threadId = Uuid.generate();
    await insert(threadId,
        priority: 1, noteScoped: false, createdAt: DateTime(2026, 1, 3));
    await insert(threadId,
        priority: 5, noteScoped: false, createdAt: DateTime(2026, 1, 2));
    await insert(threadId,
        priority: 99, noteScoped: true, createdAt: DateTime(2026, 1, 1));

    final links = await Link.watchForThread(threadId).first;

    expect(links.every((l) => !l.noteScoped), isTrue);
    expect(links.map((l) => l.priority).toList(), [5, 1]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/store/watch_for_thread_canonical_test.dart`
Expected: FAIL — current `watchForThread` returns the note-scoped link too and order is undefined.

- [ ] **Step 3: Add the filter + order**

In `apps/plot/lib/store/link.dart`, change `watchForThread` (~line 685). Update the doc-comment to note the canonical filter + order, and change the query:

```dart
  static Stream<List<Link>> watchForThread(ThreadId threadId) {
    final db = Store.get;
    return (db.select(db.links)
          ..where((l) =>
              l.threadId.equals(threadId.toBytes()) &
              l.noteScoped.equals(false))
          ..orderBy([
            // Primary-first: highest priority, then earliest created, then id
            // — matches [Thread.primaryLink] so `.first` here IS the primary.
            (l) => OrderingTerm.desc(l.priority),
            (l) => OrderingTerm.asc(l.createdAt),
            (l) => OrderingTerm.asc(l.id),
          ]))
        .watch()
        .map((rows) {
          final links = rows.map(Link.new).toList();
          _byThreadCache[threadId] = links;
          return links;
        });
  }
```

> Note: `getForThread` (used by the async `threadCommandGroups`) is intentionally left returning ALL links — `Thread.primaryLink` filters note-scoped links internally, so callers get the correct primary either way. Only `watchForThread` (the live thread-level surface) is filtered.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/store/watch_for_thread_canonical_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the link suite for regressions**

Run: `cd apps/plot && flutter test test/store/link_test.dart test/store/link_cache_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/link.dart test/store/watch_for_thread_canonical_test.dart`
Expected: No new issues.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/test/store/watch_for_thread_canonical_test.dart
git commit -m "feat(store): watchForThread returns canonical links in primary-first order"
```

---

## Task 6: `StatusIconButton` widget (glyph + status-change modal)

A reusable widget that renders a link's status glyph and, when the link type has
>1 status, opens the existing status picker (`SelectModal` → `Link.updateStatus`)
on tap. Used by the page header (Task 7) and the feed row (Task 8). It replaces
the tag-based icon in the old `_LinkStatusBadge` (which is deleted in Task 7).

**Files:**
- Create: `apps/plot/lib/widget/status_icon_button.dart`
- Test: `apps/plot/test/widget/status_icon_button_test.dart` (create)

- [ ] **Step 1: Write the failing widget test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/status_icon_button.dart';

void main() {
  test('StatusIconButton.glyphFor returns the primary status glyph', () {
    // Build a LinkTypeConfig with two statuses, current = inProgress.
    final cfg = LinkTypeConfig.fromJson({
      'type': 'issue',
      'label': 'Issue',
      'statuses': [
        {'status': 'todo', 'label': 'Todo', 'icon': 'todo'},
        {'status': 'doing', 'label': 'Doing', 'icon': 'inProgress'},
      ],
    });
    // statusIconFor resolves the LinkStatus for a raw status string.
    expect(statusIconFor(cfg, 'doing'), StatusIcon.inProgress);
    expect(statusIconFor(cfg, 'todo'), StatusIcon.todo);
    expect(statusIconFor(cfg, 'unknown'), isNull);
    expect(statusIconFor(null, 'todo'), isNull);
  });
}
```

> Note: the glyph rendering itself (a tappable forui button) is verified live via run-app in the final verification; this unit test pins the pure status→icon resolution that drives it, which is the regression-prone part.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/status_icon_button_test.dart`
Expected: FAIL — `status_icon_button.dart` does not exist.

- [ ] **Step 3: Create the widget + helper**

Create `apps/plot/lib/widget/status_icon_button.dart`. Model the picker on the existing `_LinkStatusBadge._showStatusPicker` in `page/thread.dart` (lines ~1059-1095), but render the new `StatusIcon` glyph in each row's leading instead of the old `Tag` icon / done-check:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/context.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/select_modal.dart';

/// Resolves the [StatusIcon] for a raw status string within [cfg], or null when
/// the config, status, or the status's `icon` is absent.
StatusIcon? statusIconFor(LinkTypeConfig? cfg, String? status) {
  if (cfg == null || status == null) return null;
  return cfg.statuses
      ?.where((s) => s.status == status)
      .firstOrNull
      ?.icon;
}

/// Renders [link]'s status as a single glyph. Tapping opens the status picker
/// when the link type declares more than one status. Returns an empty box when
/// the link has no resolvable status icon.
///
/// [showWhenHiddenDefault] controls whether a status flagged `hiddenDefault`
/// renders: true in the page header (always show), false on the feed row
/// (suppress resting defaults like calendar "Confirmed").
class StatusIconButton extends StatelessWidget {
  const StatusIconButton({
    required this.link,
    this.showWhenHiddenDefault = false,
    super.key,
  });

  final Link link;
  final bool showWhenHiddenDefault;

  @override
  Widget build(BuildContext context) {
    final cfg = link.getTypeConfig();
    final statuses = cfg?.statuses;
    final current =
        statuses?.where((s) => s.status == link.status).firstOrNull;
    final icon = current?.icon;
    if (icon == null) return const SizedBox.shrink();
    if (current!.hiddenDefault && !showWhenHiddenDefault) {
      return const SizedBox.shrink();
    }

    final canChange = statuses != null && statuses.length > 1;
    final glyph = Icon(
      icon.glyph,
      size: 14,
      color: context.theme.colors.mutedForeground,
    );

    if (!canChange) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: glyph,
      );
    }
    return FTooltip(
      tipBuilder: (context, controller) => Text(current.label),
      child: GestureDetector(
        onTap: () => _showStatusPicker(context, link, statuses),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: glyph,
        ),
      ),
    );
  }

  static Future<void> _showStatusPicker(
    BuildContext context,
    Link link,
    List<LinkStatus> statuses,
  ) async {
    final result = await SelectModal.open<String>(
      context,
      items: (search) async => [
        SelectGroup(items: statuses.map((s) => s.status).toList()),
      ],
      itemBuilder: (status, _) {
        final s = statuses.firstWhere((ls) => ls.status == status);
        return ListTile(
          title: s.label,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: s.icon != null
                ? Icon(
                    s.icon!.glyph,
                    size: 14,
                    color: s.status == link.status
                        ? context.theme.colors.primary
                        : context.theme.colors.mutedForeground,
                  )
                : const SizedBox(width: 14),
          ),
          disableInternalHover: true,
        );
      },
      selectedValue: link.status,
      prompt: 'Set status',
    );

    if (!result.present || !context.mounted) return;
    final selected = result.value;
    if (selected != link.status) {
      await Link.updateStatus(link, selected);
    }
  }
}
```

> Verify the imports resolve: open `page/thread.dart` and copy the exact import paths it uses for `SelectModal`, `SelectGroup`, `ListTile`, and `context.theme`/`context.colour` (the `util/context.dart` extension). Match them rather than guessing. Do NOT add a `MouseRegion`/pointer cursor — the status icon is a normal tap target (default arrow).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/status_icon_button_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/status_icon_button.dart test/widget/status_icon_button_test.dart`
Expected: No new issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/status_icon_button.dart apps/plot/test/widget/status_icon_button_test.dart
git commit -m "feat(widget): StatusIconButton renders curated status glyph + picker"
```

---

## Task 7: ThreadPage — remove per-link rows, drop connect prompt, add header status icon + join-meeting button

**Files:**
- Create: `apps/plot/lib/widget/primary_link_header_actions.dart`
- Modify: `apps/plot/lib/page/thread.dart` (remove `state.links.map(...)` block ~570-575; delete `_ThreadLinkRow`/`_ThreadLinkRowState`/`_LinkAssigneeBadge`/`_LinkStatusBadge`/`_ConferencingButton` ~785-1136; add header actions to `_ThreadActionsRow` ~1383)
- Modify: `apps/plot/lib/widget/unified_header.dart` (thread `trailing` list ~538)

This task is verified live (run-app) since it is layout-heavy; there is no cheap
widget test for the header composition. Keep the diff mechanical.

- [ ] **Step 1: Create `PrimaryLinkHeaderActions`**

Create `apps/plot/lib/widget/primary_link_header_actions.dart`. It watches the thread's canonical links, computes the primary via `Thread.primaryLink`, and renders: a join-meeting button per `ConferencingUserAction` on the primary link, then the status icon (always shown — `showWhenHiddenDefault: true`).

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/context.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/status_icon_button.dart';

/// Header actions derived from the thread's primary canonical link: a
/// join-meeting button for each conferencing action, plus the status icon
/// (always shown in the header, even for `hiddenDefault` statuses). Renders
/// nothing when the thread has no canonical link.
class PrimaryLinkHeaderActions extends HookWidget {
  const PrimaryLinkHeaderActions({required this.thread, super.key});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final snapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(thread.id), [thread.id]),
    );
    final links = snapshot.data ?? const <Link>[];
    final primary = Thread.primaryLink(links);
    if (primary == null) return const SizedBox.shrink();

    final conferencing = (primary.actions ?? const <UserAction>[])
        .whereType<ConferencingUserAction>()
        .toList();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in conferencing)
          _JoinMeetingButton(action: action),
        StatusIconButton(link: primary, showWhenHiddenDefault: true),
      ],
    );
  }
}

class _JoinMeetingButton extends StatelessWidget {
  const _JoinMeetingButton({required this.action});

  final ConferencingUserAction action;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (action.provider) {
      ConferencingProvider.googleMeet => 'Join Google Meet',
      ConferencingProvider.zoom => 'Join on Zoom',
      ConferencingProvider.microsoftTeams => 'Join on Teams',
      ConferencingProvider.webex => 'Join Webex',
      ConferencingProvider.other => 'Join Meeting',
    };
    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.tryParse(action.url);
          if (uri == null) return;
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Icon(
            PlotIcon.video,
            size: 14,
            color: context.theme.colors.foreground.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
```

> Verify import paths against an existing HookWidget that uses `useStream`/`useMemoized` (e.g. `widget/thread_sharing.dart`) and copy the exact `url_launcher`, `flutter_hooks`, and `util/context.dart` import lines. The conferencing-button body is lifted verbatim from the existing `_ConferencingButton` in `page/thread.dart` (being deleted in Step 3).

- [ ] **Step 2: Remove the per-link rows from the ThreadPage body**

In `apps/plot/lib/page/thread.dart`, delete the block (~lines 570-575):

```dart
                            ...state.links.map(
                              (link) => _ThreadLinkRow(
                                link: link,
                                thread: state.thread,
                              ),
                            ),
```

- [ ] **Step 3: Delete the now-unused private classes**

In `apps/plot/lib/page/thread.dart`, delete these classes entirely (they are only referenced by the block removed in Step 2):
- `_ThreadLinkRow` + `_ThreadLinkRowState` (~785-956)
- `_LinkAssigneeBadge` (~958-1003)
- `_LinkStatusBadge` (~1005-1096)
- `_ConferencingButton` (~1098-1136)

After deleting, grep to confirm nothing else references them:

Run: `cd apps/plot && grep -n "_ThreadLinkRow\|_LinkAssigneeBadge\|_LinkStatusBadge\|_ConferencingButton" lib/page/thread.dart`
Expected: no matches.

If `pickLinkAssignee` (used only by the deleted `_LinkAssigneeBadge`) becomes unused, leave it — it may be used elsewhere; the analyzer will flag truly-dead code. Do not delete `_ThreadLinkMenu` unless analyze shows it is now unused (it was used by `_ThreadLinkRow`; if so, delete it too).

- [ ] **Step 4: Add header actions to `_ThreadActionsRow` (multi-panel)**

In `apps/plot/lib/page/thread.dart`, in `_ThreadActionsRow.build` (~1383), add `PrimaryLinkHeaderActions` to the `endGroup` list, before the menu button:

```dart
    final endGroup = <Widget>[
      PrimaryLinkHeaderActions(thread: thread),
      if (!readOnly) ThreadSharing(thread: thread, tooltipBelow: true),
      Button.icon(_buildThreadMenuCommand(thread), tooltipBelow: true),
    ];
```

Add the import at the top of `page/thread.dart`:

```dart
import 'package:plot/widget/primary_link_header_actions.dart';
```

- [ ] **Step 5: Add header actions to the single-panel `unified_header`**

In `apps/plot/lib/widget/unified_header.dart`, in the thread `trailing` list (~538), add `PrimaryLinkHeaderActions` after the todo toggle, before sharing:

```dart
    final trailing = <Widget>[
      if (thread != null) _buildTodoToggle(context, thread),
      if (thread != null) PrimaryLinkHeaderActions(thread: thread),
      if (thread != null && !thread.isReadOnly)
        ThreadSharing(thread: thread, tooltipBelow: true),
      // ... unchanged ...
    ];
```

Add the import at the top of `unified_header.dart`:

```dart
import 'package:plot/widget/primary_link_header_actions.dart';
```

- [ ] **Step 6: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: No new issues. Fix any "unused" warnings created by Step 3 (delete genuinely-dead helpers; keep anything still referenced).

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/widget/primary_link_header_actions.dart apps/plot/lib/page/thread.dart apps/plot/lib/widget/unified_header.dart
git commit -m "feat(thread): replace per-link rows with header status icon + join-meeting button"
```

---

## Task 8: Feed row — trailing status icon (suppress hiddenDefault)

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart` (`ThreadCommands.build` ~941-1105)

- [ ] **Step 1: Compute the primary canonical link from the existing watch**

`ThreadCommands` already subscribes via `linksSnapshot = useStream(... Link.watchForThread(activity.id) ...)` (~line 1008). Just below that line, add:

```dart
    final primaryLink = Thread.primaryLink(linksSnapshot.data ?? const []);
```

- [ ] **Step 2: Render the status icon trailing (suppressed when hiddenDefault)**

In the returned `Row` (~line 1086), add a `StatusIconButton` to the trailing children. Place it after the conferencing buttons and before the RSVP chip so it sits with the other status-y trailing affordances:

```dart
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...allButtons,
        for (final action in conferencingActions)
          _ConferencingIconButton(action: action),
        if (primaryLink != null)
          StatusIconButton(link: primaryLink),
        ?rsvpChip,
        if (activity.assigneeId != null) ThreadAssignee(thread: activity),
        if (isAssociated && showCommands)
          Button.icon(DisassociateThread(activity)),
        if (trailingInset > 0) SizedBox(width: trailingInset),
      ],
    );
```

`StatusIconButton` defaults `showWhenHiddenDefault: false`, so a `hiddenDefault` status (calendar "Confirmed") renders nothing on the feed row but still shows in the header (Task 7). When the primary link has no resolvable status icon, `StatusIconButton` returns an empty box.

- [ ] **Step 3: Add the import**

At the top of `apps/plot/lib/widget/thread.dart`, add:

```dart
import 'package:plot/widget/status_icon_button.dart';
```

(`Thread` is already in scope via the store import used throughout this file.)

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/thread.dart`
Expected: No new issues.

- [ ] **Step 5: Run the thread widget tests**

Run: `cd apps/plot && flutter test test/widget/thread_header_test.dart`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/thread.dart
git commit -m "feat(feed): show primary link status icon on the thread row"
```

---

## Task 9: "Open in [Connector]" thread-menu command

**Files:**
- Create: `apps/plot/lib/command/open_thread_link.dart`
- Modify: `apps/plot/lib/command/thread.dart` (`threadCommands` ~3631, `threadCommandGroupsSync` ~3608, `threadCommandGroups` ~3589)
- Modify: `apps/plot/lib/page/thread.dart` (menu call site ~543)
- Modify: `apps/plot/lib/widget/thread.dart` (row menu call site ~891)
- Test: `apps/plot/test/command/open_thread_link_test.dart` (create)

- [ ] **Step 1: Write the failing test (command title + gating)**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/open_thread_link.dart';

void main() {
  group('OpenThreadLink', () {
    test('title names the connector', () {
      final cmd = OpenThreadLink(
        url: 'https://linear.app/x/issue/ABC-1',
        connectorName: 'Linear',
      );
      expect(cmd.title, 'Open in Linear');
    });

    test('falls back to a generic title when connector name is null', () {
      final cmd = OpenThreadLink(
        url: 'https://example.com/x',
        connectorName: null,
      );
      expect(cmd.title, 'Open in source');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/command/open_thread_link_test.dart`
Expected: FAIL — `open_thread_link.dart` does not exist.

- [ ] **Step 3: Create the command**

Create `apps/plot/lib/command/open_thread_link.dart`. Model the `Command` shape on `OpenPageLink` in `command/page_link.dart` (constructor calling `super(title:..., eventObject:..., eventAction:..., icon:...)`, async `run`). It launches the external URL:

```dart
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'command.dart';
import 'logging.dart';

/// Opens the thread's primary canonical link in its source application.
/// Surfaced only when a primary canonical link with a URL exists (the call
/// sites gate on that — see threadCommands).
class OpenThreadLink extends Command {
  OpenThreadLink({required this.url, required this.connectorName})
    : super(
        title: connectorName != null
            ? 'Open in $connectorName'
            : 'Open in source',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.arrowUpRightFromSquare,
      );

  final String url;
  final String? connectorName;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return CommandMessage('Invalid link', isError: true);
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open thread link: $url', e, t);
      return CommandMessage('Failed to open link', isError: true);
    }
  }
}
```

> Verify `EventObject.navigation`, `EventAction.clicked`, `CommandReturn`, `CommandMessage`, `CommandDone`, and `log` resolve exactly as in `command/page_link.dart` (same import of `command.dart` + `logging.dart`). `FontAwesomeIcons.arrowUpRightFromSquare` is the standard "open external" glyph; if analyze flags it, this file is the only place adding it — bump `FONT_CACHE_VERSION` again (20→21) if a new glyph is introduced here. (Prefer reusing `FontAwesomeIcons.link` to avoid a second font bump if unsure.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/plot && flutter test test/command/open_thread_link_test.dart`
Expected: PASS.

- [ ] **Step 5: Thread an `openInLink` param through the command builders**

In `apps/plot/lib/command/thread.dart`:

Add a parameter to `threadCommands` (~3631) and emit the command when set. Add to the signature:

```dart
  Link? openInLink,
```

Then inside the non-read-only return list (after `ChangeCurrentThread`, near the top, ~3670), insert:

```dart
    if (openInLink?.sourceUrl != null)
      OpenThreadLink(
        url: openInLink!.sourceUrl!,
        connectorName: openInLink.createdBy == null
            ? null
            : TwistInstance.fromCache(openInLink.createdBy!)?.name,
      ),
```

Add the import at the top of `command/thread.dart`:

```dart
import 'package:plot/command/open_thread_link.dart';
```

Plumb the param through `threadCommandGroupsSync` (~3608) — add `Link? openInLink,` to its signature and pass `openInLink: openInLink` into its `threadCommands(...)` call. Do the same for the async `threadCommandGroups` (~3589): after `final links = await Link.getForThread(thread.id);`, compute `final primary = Thread.primaryLink(links);` and pass `openInLink: primary` into `threadCommandGroupsSync(...)`.

- [ ] **Step 6: Pass the primary link at the page menu call site**

In `apps/plot/lib/page/thread.dart` (~543), the page menu builds commands with `threadCommandGroupsSync(state.thread, ...)`. Add the primary link:

```dart
                      ...threadCommandGroupsSync(
                        state.thread,
                        isPlotThread: Thread.isPlotThread(state.links),
                        sharingModel: Thread.resolveSharingModel(state.links),
                        openInLink: Thread.primaryLink(state.links),
                        priorityBloc: priorityBloc,
                      ),
```

- [ ] **Step 7: Pass the primary link at the row-menu call site**

In `apps/plot/lib/widget/thread.dart`, the row context menu calls `threadCommands(...)` (~891). `ThreadCommands.build` already has `primaryLink` from Task 8. Pass it through. Locate the `threadCommands(` call inside the `items: (close) =>` builder (~891) and add `openInLink: primaryLink,` to its arguments.

> If that menu builder is in a different method/scope than `build` (where `primaryLink` is defined), compute the primary there from `Link.cachedForThread(activity.id)` (synchronous cache, already warmed) or a local `useStream`, mirroring how the surrounding code accesses links. Prefer reusing the `primaryLink` local if it is in scope.

- [ ] **Step 8: Analyze the whole app**

Run: `cd apps/plot && flutter analyze`
Expected: No new issues.

- [ ] **Step 9: Run the command tests**

Run: `cd apps/plot && flutter test test/command/`
Expected: PASS (no regressions in `thread_test.dart`, `thread_merge_test.dart`, etc.).

- [ ] **Step 10: Commit**

```bash
git add apps/plot/lib/command/open_thread_link.dart apps/plot/lib/command/thread.dart apps/plot/lib/page/thread.dart apps/plot/lib/widget/thread.dart apps/plot/test/command/open_thread_link_test.dart
git commit -m "feat(thread): add Open in [Connector] command for the primary link"
```

---

## Final verification

- [ ] **Full analyze:** `cd apps/plot && flutter analyze` → 0 new issues.
- [ ] **Targeted tests:** `cd apps/plot && flutter test test/store test/widget/status_icon_button_test.dart test/command/open_thread_link_test.dart test/widget/thread_header_test.dart` → all pass.
- [ ] **Live UI (run-app skill):** launch the macOS app in the `agent` profile and confirm:
  1. A connector thread with a status (e.g. Linear issue, Google Calendar event) shows **one** status icon in the page header; tapping it opens the status picker; selecting a new status updates it.
  2. The same thread's feed row shows the status icon trailing — **except** a Google Calendar "Confirmed" event (hiddenDefault) shows **no** icon on the feed row but **does** show it in the header.
  3. There are **no** per-link header rows above the notes list, and **no** "Connect your account" prompt.
  4. A calendar event with a meeting link shows a **join-meeting** button in the header.
  5. The thread menu (page menu + feed-row "…" menu) shows **"Open in [Connector]"** for a thread with a primary canonical link that has a URL; clicking it opens the external item.
  6. A Plot-native thread (no canonical link) and a Granola-only thread (note-scoped link, before a calendar connects) show **no** status icon and **no** "Open in" command.
- [ ] **Web guard sanity:** confirm no new `dart:io` `Platform.isX` calls were introduced (grep the touched files).
- [ ] **/finalize:** run the `finalize` skill (lint, backwards-compat, docs). Add a user-facing bullet to `docs/updates.md` (e.g. "Threads now show a single status icon for the linked item, with quick status changes and an Open in [app] action.").

---

## Self-review notes (author)

- **Spec coverage:** model columns (T1), icon/hiddenDefault parse (T2), glyph map (T3), one primary-link helper routing all four consumers (T4), canonical+ordered watch (T5), reusable status icon widget (T6), header status icon + join-meeting + removed rows + dropped connect prompt (T7), feed-row status icon with hiddenDefault suppression (T8), Open in [Connector] command in both menus (T9). All scope items covered.
- **Type consistency:** `StatusIcon` enum + `StatusIcon.fromJson`/`.glyph`; `Link.priority`/`Link.noteScoped`; `Thread.primaryLink(List<Link>) → Link?`; `StatusIconButton({link, showWhenHiddenDefault})`; `statusIconFor(LinkTypeConfig?, String?) → StatusIcon?`; `OpenThreadLink({url, connectorName})`; `threadCommands(..., openInLink)` consistent across T4/T6/T9 and all call sites.
- **Note-scoped links:** excluded from thread-level surfacing via `watchForThread` filter (T5) and `Thread.primaryLink` (T4); inline note rendering is a separate, untouched path.
- **Cursor / web / format conventions** are restated in the Background section and applied in the widget tasks.
