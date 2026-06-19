# Never-lose Drafts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make draft threads durable — never destroyed by starting a new draft — and surface all drafts in a "Drafts" section at the top of the New thread picker, with discard (archive) and a show-archived restore path.

**Architecture:** Drafts are existing `thread` rows with `draft = true` (active = `archived_at IS NULL`, discarded = archived). No schema change. Pure helpers decide whether a draft is "substantive" (worth keeping/listing) and derive its tile label. The `ComposeTargetsBloc.loadSections` builds a list of `DraftSummary` from the store; `ComposeSectionsView` renders them as a top section of `PillGrid` rows (reusing keyboard nav + highlight) with an always-visible trailing ✕ (discard) or restore icon. `PriorityBloc` gains `startFreshDraft()` (preserve the current substantive draft, mint a fresh empty one) and `resumeDraft()`, replacing the old destructive reuse-and-clear. The per-focus dedup that archived extra drafts is removed.

**Tech Stack:** Flutter, flutter_bloc (Cubit/Bloc), Drift (SQLite, local), forui widgets, auto_route.

## Global Constraints

- **UI imports:** Only `package:flutter/widgets.dart` and `package:forui/forui.dart` for UI — never `package:flutter/material.dart`. Use existing `lib/widget/` components.
- **Strict typing:** `strict-casts`, `strict-inference`, `strict-raw-types`. No raw types.
- **UI text is sentence case:** e.g. section header `Drafts`, fallback label `Untitled draft`.
- **No Drift schema change:** drafts reuse existing `thread.draft` and `thread.archived_at`. Do NOT bump `Store.schemaVersion` or run `build_runner` — no codegen is needed (no new Drift column, no new auto_route page).
- **Drafts are local-only:** `draft = true` rows are excluded from server sync (`Store._buildDraftFilter`), so discarding archives via `archived_at = now()` (soft) — never hard-delete. Both the active and archived draft lists filter by the substantive predicate, so empty/skeleton drafts never appear even if archived.
- **Error capture:** any new `catch` for an *unexpected* error calls `Tracker.captureException(e, s)`. Do not capture expected/handled cases.
- **Commands:** state-affecting user actions are `Command` subclasses in `lib/command/`.
- **Lint gate:** run `cd apps/plot && flutter analyze` before every commit; it must be clean.
- **Cursor:** do not add web pointer cursors to draft tiles or buttons (desktop-style arrow is default).

## File Map

- Create `apps/plot/lib/util/draft.dart` — pure helpers: substantive predicate, label, snippet. (Task 1)
- Create `apps/plot/test/util/draft_test.dart` — unit tests for Task 1.
- Modify `apps/plot/lib/state/compose_targets.dart` — `DraftSummary`, `DraftInput`, pure `buildDraftSummaries`, `ComposeSections.drafts`, draft loading in `loadSections`. (Tasks 2, 3)
- Create `apps/plot/test/state/draft_summaries_test.dart` — unit tests for Task 2.
- Modify `apps/plot/lib/widget/compose/compose_pill.dart` — `DraftPillData` + render arm. (Task 4)
- Modify `apps/plot/lib/widget/compose/pill_grid.dart` — always-visible `trailing` on rows. (Task 5)
- Modify `apps/plot/lib/widget/compose/compose_sections_view.dart` — Drafts section, new params, reload. (Task 6)
- Modify `apps/plot/lib/state/priority.dart` — `startFreshDraft`, `resumeDraft`; remove dedup. (Task 7)
- Modify `apps/plot/lib/command/thread.dart` — `DiscardDraft`, `RestoreDraft`. (Task 8)
- Modify `apps/plot/lib/page/new_thread.dart` — wire fresh-draft, drafts callbacks, revision/show-archived. (Task 9)
- Modify `apps/plot/docs/updates.md` — user-facing bullet. (Task 10)

---

### Task 1: Pure draft helpers

**Files:**
- Create: `apps/plot/lib/util/draft.dart`
- Test: `apps/plot/test/util/draft_test.dart`

**Interfaces:**
- Produces:
  - `bool isSubstantiveDraftFields({required String? title, required bool hasRecipients, required bool hasSchedule, required String? body, required bool hasActions})`
  - `String? draftBodySnippet(String? content, {int maxLen = 80})`
  - `String draftPrimaryLabel({required String? title, required String? bodySnippet, required String? recipientSummary})`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/util/draft_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/draft.dart';

void main() {
  group('isSubstantiveDraftFields', () {
    bool sub({
      String? title,
      bool hasRecipients = false,
      bool hasSchedule = false,
      String? body,
      bool hasActions = false,
    }) => isSubstantiveDraftFields(
          title: title,
          hasRecipients: hasRecipients,
          hasSchedule: hasSchedule,
          body: body,
          hasActions: hasActions,
        );

    test('all empty → not substantive', () {
      expect(sub(), isFalse);
      expect(sub(title: '   ', body: ''), isFalse);
    });
    test('any single dimension → substantive', () {
      expect(sub(title: 'Hi'), isTrue);
      expect(sub(hasRecipients: true), isTrue);
      expect(sub(hasSchedule: true), isTrue);
      expect(sub(body: 'note text'), isTrue);
      expect(sub(hasActions: true), isTrue);
    });
    test('whitespace-only title/body do not count', () {
      expect(sub(title: '  ', body: '\n  \t'), isFalse);
    });
  });

  group('draftBodySnippet', () {
    test('null/empty → null', () {
      expect(draftBodySnippet(null), isNull);
      expect(draftBodySnippet('   '), isNull);
    });
    test('first non-empty line, trimmed', () {
      expect(draftBodySnippet('\n  first line\nsecond'), 'first line');
    });
    test('truncates to maxLen with ellipsis', () {
      final s = draftBodySnippet('a' * 200, maxLen: 10);
      expect(s, '${'a' * 10}…');
    });
  });

  group('draftPrimaryLabel', () {
    test('prefers title, then snippet, then recipients, then fallback', () {
      expect(
        draftPrimaryLabel(title: 'T', bodySnippet: 'B', recipientSummary: 'R'),
        'T',
      );
      expect(
        draftPrimaryLabel(title: '  ', bodySnippet: 'B', recipientSummary: 'R'),
        'B',
      );
      expect(
        draftPrimaryLabel(title: null, bodySnippet: null, recipientSummary: 'R'),
        'R',
      );
      expect(
        draftPrimaryLabel(title: null, bodySnippet: null, recipientSummary: null),
        'Untitled draft',
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/util/draft_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'plot' ... util/draft.dart` / undefined functions.

- [ ] **Step 3: Write minimal implementation**

Create `apps/plot/lib/util/draft.dart`:

```dart
/// Pure helpers for the never-lose-drafts feature. No store / Flutter imports
/// so they unit-test in isolation (see test/util/draft_test.dart).

/// Whether a draft holds user content worth keeping and listing. A draft with
/// none of these is a "skeleton" the page minted to compose into; it is never
/// listed (active or archived).
bool isSubstantiveDraftFields({
  required String? title,
  required bool hasRecipients,
  required bool hasSchedule,
  required String? body,
  required bool hasActions,
}) {
  if ((title?.trim().isNotEmpty ?? false)) return true;
  if (hasRecipients) return true;
  if (hasSchedule) return true;
  if ((body?.trim().isNotEmpty ?? false)) return true;
  if (hasActions) return true;
  return false;
}

/// The first non-empty line of [content], trimmed and truncated to [maxLen]
/// (with a trailing ellipsis when truncated). Null when there is no text.
String? draftBodySnippet(String? content, {int maxLen = 80}) {
  if (content == null) return null;
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.length <= maxLen) return line;
    return '${line.substring(0, maxLen)}…';
  }
  return null;
}

/// The tile label for a draft: title → body snippet → recipient summary →
/// "Untitled draft". Inputs are pre-resolved by the caller.
String draftPrimaryLabel({
  required String? title,
  required String? bodySnippet,
  required String? recipientSummary,
}) {
  final t = title?.trim();
  if (t != null && t.isNotEmpty) return t;
  final b = bodySnippet?.trim();
  if (b != null && b.isNotEmpty) return b;
  final r = recipientSummary?.trim();
  if (r != null && r.isNotEmpty) return r;
  return 'Untitled draft';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/util/draft_test.dart`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/util/draft.dart apps/plot/test/util/draft_test.dart
git commit -m "$(cat <<'EOF'
feat(drafts): pure helpers for substantive predicate and tile label

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `DraftSummary` model + pure `buildDraftSummaries`

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` (add classes near `ComposeSections`, ~line 22-64)
- Test: `apps/plot/test/state/draft_summaries_test.dart`

**Interfaces:**
- Consumes: `isSubstantiveDraftFields`, `draftPrimaryLabel` (Task 1).
- Produces:
  - `class DraftInput` — raw per-draft fields fed from the store.
  - `class DraftSummary extends Equatable` — `{ Uuid threadId; String label; String? detail; String? icon; bool archived; }`
  - `List<DraftSummary> buildDraftSummaries(List<DraftInput> active, List<DraftInput> archived, {int archivedLimit = 5})`

**Notes:** `Uuid` is imported in this file already (`package:plot/util/uuid.dart`). `Equatable` is used by `ComposeSections` already (import present).

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/draft_summaries_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/util/uuid.dart';

void main() {
  DraftInput input(
    String hex, {
    String? title,
    bool hasRecipients = false,
    bool hasSchedule = false,
    String? body,
    bool hasActions = false,
    String? recipientSummary,
    String? icon,
    required int sortMs,
    bool archived = false,
  }) =>
      DraftInput(
        threadId: Uuid.fromString('00000000-0000-0000-0000-0000000000$hex'),
        title: title,
        hasRecipients: hasRecipients,
        hasSchedule: hasSchedule,
        body: body,
        hasActions: hasActions,
        recipientSummary: recipientSummary,
        icon: icon,
        sortKey: DateTime.fromMillisecondsSinceEpoch(sortMs),
        archived: archived,
      );

  test('drops skeleton drafts (no content)', () {
    final out = buildDraftSummaries(
      [input('01', sortMs: 1), input('02', title: 'Real', sortMs: 2)],
      const [],
    );
    expect(out.map((d) => d.label), ['Real']);
  });

  test('orders active drafts most-recent first', () {
    final out = buildDraftSummaries(
      [
        input('01', title: 'Old', sortMs: 1),
        input('02', title: 'New', sortMs: 9),
        input('03', title: 'Mid', sortMs: 5),
      ],
      const [],
    );
    expect(out.map((d) => d.label), ['New', 'Mid', 'Old']);
  });

  test('label falls back recipients → Untitled', () {
    final out = buildDraftSummaries(
      [
        input('01', recipientSummary: 'To: Bob', sortMs: 2),
        input('02', hasSchedule: true, sortMs: 1),
      ],
      const [],
    );
    expect(out.map((d) => d.label), ['To: Bob', 'Untitled draft']);
  });

  test('archived drafts appended after active, capped at limit, recency order',
      () {
    final archived = [
      for (var i = 0; i < 8; i++)
        input('1$i', title: 'A$i', sortMs: i, archived: true),
    ];
    final out = buildDraftSummaries(
      [input('01', title: 'Active', sortMs: 100)],
      archived,
      archivedLimit: 5,
    );
    expect(out.first.label, 'Active');
    expect(out.first.archived, isFalse);
    final archivedOut = out.where((d) => d.archived).toList();
    expect(archivedOut.length, 5);
    // Most-recently-archived (highest sortMs) first.
    expect(archivedOut.map((d) => d.label), ['A7', 'A6', 'A5', 'A4', 'A3']);
  });

  test('skeleton archived drafts are excluded before the cap', () {
    final archived = [
      input('11', sortMs: 5, archived: true), // skeleton, dropped
      input('12', title: 'Keep', sortMs: 4, archived: true),
    ];
    final out = buildDraftSummaries(const [], archived, archivedLimit: 5);
    expect(out.map((d) => d.label), ['Keep']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/draft_summaries_test.dart`
Expected: FAIL — `DraftInput`/`DraftSummary`/`buildDraftSummaries` undefined.

- [ ] **Step 3: Write minimal implementation**

In `apps/plot/lib/state/compose_targets.dart`, add the import at the top with the other `package:plot/...` imports:

```dart
import 'package:plot/util/draft.dart';
```

Then add these classes/functions immediately above `class ComposeSections` (around line 41):

```dart
/// Raw per-draft fields the bloc extracts from a draft thread + its draft note,
/// fed into the pure [buildDraftSummaries]. Kept primitive so the assembly is
/// store-free and unit-testable.
class DraftInput {
  const DraftInput({
    required this.threadId,
    required this.title,
    required this.hasRecipients,
    required this.hasSchedule,
    required this.body,
    required this.hasActions,
    required this.recipientSummary,
    required this.icon,
    required this.sortKey,
    required this.archived,
  });

  final Uuid threadId;
  final String? title;
  final bool hasRecipients;
  final bool hasSchedule;
  final String? body;
  final bool hasActions;

  /// A pre-resolved "To: …" summary used as the label when there is no title
  /// or body. Null when the draft has no recipients.
  final String? recipientSummary;

  /// Optional leading-glyph hint (favicon URL, or null for the default glyph).
  final String? icon;

  /// Recency key for ordering (updatedAt for active, archivedAt for archived).
  final DateTime sortKey;
  final bool archived;
}

/// A draft row ready to render as a picker tile.
class DraftSummary extends Equatable {
  const DraftSummary({
    required this.threadId,
    required this.label,
    required this.detail,
    required this.icon,
    required this.archived,
  });

  final Uuid threadId;
  final String label;
  final String? detail;
  final String? icon;
  final bool archived;

  @override
  List<Object?> get props => [threadId, label, detail, icon, archived];
}

/// Filters [active] and [archived] draft inputs to substantive drafts, orders
/// each group most-recent first, caps [archived] to [archivedLimit], and
/// returns active drafts followed by archived ones.
List<DraftSummary> buildDraftSummaries(
  List<DraftInput> active,
  List<DraftInput> archived, {
  int archivedLimit = 5,
}) {
  bool substantive(DraftInput d) => isSubstantiveDraftFields(
        title: d.title,
        hasRecipients: d.hasRecipients,
        hasSchedule: d.hasSchedule,
        body: d.body,
        hasActions: d.hasActions,
      );

  DraftSummary summary(DraftInput d) => DraftSummary(
        threadId: d.threadId,
        label: draftPrimaryLabel(
          title: d.title,
          bodySnippet: draftBodySnippet(d.body),
          recipientSummary: d.recipientSummary,
        ),
        detail: null,
        icon: d.icon,
        archived: d.archived,
      );

  final activeOut = active.where(substantive).toList()
    ..sort((a, b) => b.sortKey.compareTo(a.sortKey));
  final archivedOut = archived.where(substantive).toList()
    ..sort((a, b) => b.sortKey.compareTo(a.sortKey));

  return [
    ...activeOut.map(summary),
    ...archivedOut.take(archivedLimit).map(summary),
  ];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/draft_summaries_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/state/compose_targets.dart apps/plot/test/state/draft_summaries_test.dart
git commit -m "$(cat <<'EOF'
feat(drafts): DraftSummary model + pure buildDraftSummaries assembler

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Load drafts in `ComposeSections` / `ComposeTargetsBloc`

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart` — `ComposeSections` (add `drafts`), `loadSections`, `searchSections`.

**Interfaces:**
- Consumes: `DraftSummary`, `DraftInput`, `buildDraftSummaries` (Task 2); `Thread.get`, `Note.getDraftByActivity`, `Actor.fromCache`/`Group.fromCache` (existing store).
- Produces: `ComposeSections.drafts` (`List<DraftSummary>`); `loadSections({bool includeArchivedDrafts = false, ...})`.

**Verification:** store-backed glue — verified by `flutter analyze` and the run-app pass in Task 10 (the pure assembly is already covered by Task 2). No new unit test.

- [ ] **Step 1: Add `drafts` to `ComposeSections`**

In `class ComposeSections` (around line 41-64) add the field to the constructor, the declaration, and `props`:

```dart
class ComposeSections extends Equatable {
  const ComposeSections({
    required this.people,
    required this.twists,
    required this.channels,
    required this.focuses,
    this.drafts = const [],
    this.priorityById = const {},
  });
  final List<ComposePeopleEntry> people;
  final List<ComposeTarget> twists;
  final List<ComposeTarget> channels;
  final List<ComposeTarget> focuses;

  /// Draft threads to surface as a top "Drafts" section (most-recent first,
  /// then up to 5 most-recently-archived when show-archived is on). Empty in
  /// link mode and during search. See [ComposeTargetsBloc.loadSections].
  final List<DraftSummary> drafts;

  final Map<Uuid, Priority> priorityById;

  @override
  List<Object?> get props => [people, twists, channels, focuses, drafts];
}
```

- [ ] **Step 2: Add a draft-loading helper to `ComposeTargetsBloc`**

Add this private method to `ComposeTargetsBloc` (anywhere among its methods, e.g. just below `loadSections`). It reads draft threads + their draft notes and maps them to `DraftInput`:

```dart
  /// Builds the draft summaries for the picker: substantive active drafts
  /// (most-recent first) plus, when [includeArchived], up to 5 most-recently
  /// archived drafts. Returns [] when the store is unavailable.
  Future<List<DraftSummary>> _loadDraftSummaries({
    required bool includeArchived,
  }) async {
    if (!Store.isAvailable) return const [];

    Future<DraftInput> toInput(Thread t, {required bool archived}) async {
      final note = await Note.getDraftByActivity(t.id);
      final hasRecipients =
          t.contacts.isNotEmpty || t.groups.isNotEmpty || t.inviteEmails.isNotEmpty;
      return DraftInput(
        threadId: t.id,
        title: t.title,
        hasRecipients: hasRecipients,
        hasSchedule: t.at != null || t.on != null,
        body: note?.content,
        hasActions: note?.actions?.isNotEmpty ?? false,
        recipientSummary: _draftRecipientSummary(t),
        icon: (t.icon != null && t.icon!.startsWith('http')) ? t.icon : null,
        sortKey: archived ? (t.archivedAt ?? t.updatedAt) : t.updatedAt,
        archived: archived,
      );
    }

    final activeThreads = await Thread.get(draft: true, archived: false);
    final active = [
      for (final t in activeThreads) await toInput(t, archived: false),
    ];

    var archived = const <DraftInput>[];
    if (includeArchived) {
      final archivedThreads = await Thread.get(draft: true, archived: true);
      archived = [
        for (final t in archivedThreads) await toInput(t, archived: true),
      ];
    }

    return buildDraftSummaries(active, archived);
  }

  /// A short "To: …" summary of a draft's recipients, resolved from the warm
  /// Actor/Group caches. Null when the draft has no recipients.
  String? _draftRecipientSummary(Thread t) {
    final names = <String>[];
    for (final c in t.contacts) {
      final a = Actor.fromCache(ActorId.fromUuid(c));
      final n = a?.name ?? a?.email;
      if (n != null && n.isNotEmpty) names.add(n);
    }
    for (final g in t.groups) {
      final grp = Group.fromCache(g);
      if (grp != null && grp.name.isNotEmpty) names.add(grp.name);
    }
    names.addAll(t.inviteEmails);
    if (names.isEmpty) return null;
    final shown = names.take(3).join(', ');
    final extra = names.length - 3;
    return extra > 0 ? 'To: $shown +$extra' : 'To: $shown';
  }
```

> Note: `ActorId.fromUuid`, `Actor.fromCache`, `Group.fromCache` are the same helpers `searchSections` uses (see its `matchesEntry`). Confirm the exact names while editing; mirror that method.

- [ ] **Step 3: Thread the drafts through `loadSections`**

Change `loadSections`'s signature to accept `includeArchivedDrafts` and build drafts. Update the signature (around line 901):

```dart
  Future<ComposeSections> loadSections({
    int perSection = 8,
    bool linkMode = false,
    Uuid? currentFocusId,
    bool includeArchivedDrafts = false,
  }) async {
```

After the early `if (!Store.isAvailable)` guard, leave it returning `const ComposeSections(people: [], twists: [], channels: [], focuses: [])` (drafts defaults to `const []`).

Compute drafts once near the top of the body (after the `Store.isAvailable` guard), but only outside link mode:

```dart
    final drafts = linkMode
        ? const <DraftSummary>[]
        : await _loadDraftSummaries(includeArchived: includeArchivedDrafts);
```

Then add `drafts: drafts,` to BOTH `ComposeSections(...)` return sites in `loadSections` — the `linkMode` branch's `linkModeSections(ComposeSections(... ))` inner constructor can keep `drafts: const []` (link mode shows none), and the final normal-mode `return ComposeSections(...)` gets `drafts: drafts,`. Concretely, the final return becomes:

```dart
    return ComposeSections(
      people: people,
      twists: twists.take(perSection).toList(),
      channels: allChannels.take(perSection).toList(),
      focuses: allFocuses.take(perSection).toList(),
      drafts: drafts,
      priorityById: ctx.priorityById,
    );
```

- [ ] **Step 4: Omit drafts during search**

In `searchSections` (around line 1175), the final `return ComposeSections(...)` must pass `drafts: const []` (searching filters targets, not drafts). Add `drafts: const [],` to that constructor. Also, `searchSections` calls `loadSections(perSection: _kSearchPoolLimit, currentFocusId: ...)` for its base — that's fine; we discard the base's drafts by returning `const []`.

- [ ] **Step 5: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors (warnings unrelated to these files are out of scope).

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/state/compose_targets.dart
git commit -m "$(cat <<'EOF'
feat(drafts): load active + archived draft summaries in ComposeSections

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `DraftPillData` + render arm

**Files:**
- Modify: `apps/plot/lib/widget/compose/compose_pill.dart`

**Interfaces:**
- Produces: `class DraftPillData extends ComposePillData { final String label; final String? detail; final String? icon; }`

**Verification:** visual — verified by `flutter analyze` (the sealed switch must be exhaustive) + run-app (Task 10).

- [ ] **Step 1: Add the sealed subclass**

In `compose_pill.dart`, alongside the other `*PillData` classes (after `ConnectionPillData`, ~line 90), add:

```dart
/// A draft row: a draft glyph (or favicon) + the draft's label + an optional
/// muted recipient/focus detail.
class DraftPillData extends ComposePillData {
  const DraftPillData(this.label, {this.detail, this.icon});
  final String label;
  final String? detail;
  /// Favicon URL when the draft carries a link; null → default draft glyph.
  final String? icon;
}
```

- [ ] **Step 2: Add the render arm**

In `ComposePill`'s content `switch` (the expression that handles each `ComposePillData` variant — model on the `FocusPillData` / `ConnectionPillData` arms around lines 336-380), add a `DraftPillData` arm. Use the shared `_gutter(...)` + name pattern. For the leading glyph use `PlotIcon.note` (or the existing draft/note glyph used elsewhere — confirm the constant in `lib/widget/icon.dart`; do NOT invent one). Example arm:

```dart
      DraftPillData(:final label, :final detail, :final icon) => _gutterRow(
          context,
          leading: const Icon(PlotIcon.note),
          name: label,
          meta: detail,
        ),
```

> Match the exact helper the other arms use to render `leading + name + meta` — in this file that is `_gutter(...)` composed with a `Text`/`_nameLine`. Mirror the `ConnectionPillData` arm's structure exactly rather than introducing a new helper. If a favicon `icon` is present, render it like the connector logo arms (see the `ChannelPillData`/`ConnectionPillData` logo handling) instead of `PlotIcon.note`.

- [ ] **Step 3: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors. (A non-exhaustive switch would error here — confirms the arm is wired.)

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/compose/compose_pill.dart
git commit -m "$(cat <<'EOF'
feat(drafts): DraftPillData pill variant for draft tiles

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Always-visible trailing action on `PillGrid` rows

**Files:**
- Modify: `apps/plot/lib/widget/compose/pill_grid.dart`

**Interfaces:**
- Consumes: existing `PillGridItem` (Task analysis).
- Produces: `PillGridItem.trailing` (`Widget?`) — an always-visible trailing widget; when set it replaces the highlight-gated `onMore` button for that row.

**Verification:** `flutter analyze` + run-app (Task 10).

- [ ] **Step 1: Add the field to `PillGridItem`**

Change `PillGridItem` (lines 15-28) to:

```dart
class PillGridItem {
  PillGridItem({
    required this.data,
    required this.onActivate,
    this.onMore,
    this.trailing,
  });

  final ComposePillData data;
  final VoidCallback onActivate;

  /// Optional "… More" action (Edit). When non-null, the row shows a trailing
  /// "…" button while highlighted and Cmd+Enter on the highlighted row fires it.
  final VoidCallback? onMore;

  /// An always-visible trailing widget (e.g. a draft's discard ✕ or restore
  /// icon). When set it takes the trailing slot in place of [onMore]'s
  /// highlight-gated button.
  final Widget? trailing;
}
```

- [ ] **Step 2: Render it in the row**

In `build()`'s per-item `Row` (lines 261-295), replace the trailing `if (item.onMore != null) Opacity(...)` block so an explicit `trailing` always shows and `onMore` keeps its existing highlight-gated behavior otherwise:

```dart
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: item.onActivate,
                  child: ComposePill(data: item.data),
                ),
              ),
              if (item.trailing != null)
                item.trailing!
              else if (item.onMore != null)
                Opacity(
                  opacity: index == _highlighted ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: index != _highlighted,
                    child: _moreButton(context, item.onMore!),
                  ),
                ),
            ],
          ),
```

- [ ] **Step 3: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/compose/pill_grid.dart
git commit -m "$(cat <<'EOF'
feat(drafts): always-visible trailing slot on PillGrid rows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Render the Drafts section in `ComposeSectionsView`

**Files:**
- Modify: `apps/plot/lib/widget/compose/compose_sections_view.dart`

**Interfaces:**
- Consumes: `ComposeSections.drafts`, `DraftSummary`, `DraftPillData` (Tasks 3, 4); `PillGridItem.trailing` (Task 5).
- Produces: new `ComposeSectionsView` params:
  - `final int draftsRevision;` (default 0)
  - `final bool showArchivedDrafts;` (default false)
  - `final void Function(Uuid threadId, bool archived)? onResumeDraft;`
  - `final void Function(Uuid threadId)? onDiscardDraft;`
  - `final void Function(Uuid threadId)? onRestoreDraft;`

**Verification:** `flutter analyze` + run-app (Task 10).

- [ ] **Step 1: Add the constructor params + fields**

In the constructor (lines 53-69) add (after `pinnedFocusId`):

```dart
    this.draftsRevision = 0,
    this.showArchivedDrafts = false,
    this.onResumeDraft,
    this.onDiscardDraft,
    this.onRestoreDraft,
```

And the field declarations (after the `pinnedFocusId` field, ~line 131):

```dart
  /// Bumped by the host after a draft mutation (discard / restore / resume /
  /// start-fresh) to force a reload of the Drafts section.
  final int draftsRevision;

  /// Whether the global "show archived items" preference is on — surfaces up
  /// to 5 most-recently-archived drafts in the Drafts section.
  final bool showArchivedDrafts;

  /// Resume a draft: load it as the working draft and jump to compose. The
  /// [archived] flag tells the host to restore it first.
  final void Function(Uuid threadId, bool archived)? onResumeDraft;

  /// Discard (archive) an active draft.
  final void Function(Uuid threadId)? onDiscardDraft;

  /// Restore an archived draft without opening it (the row body still resumes).
  final void Function(Uuid threadId)? onRestoreDraft;
```

- [ ] **Step 2: Pass `includeArchivedDrafts` into the load**

In `_loadSections()` (lines 227-249) change the bloc call to forward the flag:

```dart
  bloc
      .loadSections(
        linkMode: _linkMode,
        currentFocusId: widget.pinnedFocusId,
        includeArchivedDrafts: widget.showArchivedDrafts,
      )
      .then((sections) {
```

- [ ] **Step 3: Reload when revision / show-archived changes**

Find `didUpdateWidget` (around line 203). Add, alongside its existing reload triggers, a reload when the drafts inputs change. Add this inside `didUpdateWidget` (after `super.didUpdateWidget(old)`):

```dart
    if (old.draftsRevision != widget.draftsRevision ||
        old.showArchivedDrafts != widget.showArchivedDrafts) {
      // Only the at-rest (non-search) view shows drafts; reloading is a no-op
      // for the filtered list (searchSections returns no drafts).
      if (widget.searchController.text.trim().isEmpty) _loadSections();
    }
```

- [ ] **Step 4: Build the Drafts section first in `_buildSections`**

At the very top of `_buildSections()` (line 290, right after `final s = _sections; if (s == null) return const [];`), build the drafts section and prepend it. Add a helper `_draftItems()` and a discard/restore button builder. Insert into `_buildSections`:

```dart
    // Drafts lead the picker (most-recent first, then archived when shown).
    // Empty in link mode and during search (s.drafts is [] there).
    final draftItems = [
      for (final d in s.drafts)
        PillGridItem(
          data: DraftPillData(d.label, detail: d.detail, icon: d.icon),
          onActivate: () => widget.onResumeDraft?.call(d.threadId, d.archived),
          trailing: d.archived
              ? _draftTrailingButton(
                  icon: PlotIcon.refresh,
                  tooltip: 'Restore draft',
                  onPress: () => widget.onRestoreDraft?.call(d.threadId),
                )
              : _draftTrailingButton(
                  icon: PlotIcon.close,
                  tooltip: 'Discard draft',
                  onPress: () => widget.onDiscardDraft?.call(d.threadId),
                ),
        ),
    ];
    final PillGridSection? draftsSection = draftItems.isEmpty
        ? null
        : PillGridSection(header: _sectionHeader('Drafts'), items: draftItems);
```

Then include `draftsSection` at the FRONT of the `ordered` list near the end of `_buildSections`:

```dart
    final ordered = _linkMode
        ? <PillGridSection?>[draftsSection, focusSection, channelSection]
        : <PillGridSection?>[
            draftsSection,
            peopleSection,
            channelSection,
            focusSection,
          ];
    return [for (final sec in ordered) ?sec];
```

> In link mode `draftsSection` will be null (drafts are `[]`), so this is harmless; keeping it in both arms avoids divergence.

- [ ] **Step 5: Add the trailing-button builder**

Add a private method to `_ComposeSectionsViewState` (near `_headerGhostButton` / `_moreButton` siblings). Use `FButton` ghost like the existing `_moreButton` in `pill_grid.dart`; confirm `PlotIcon.close` / `PlotIcon.refresh` exist in `lib/widget/icon.dart` (use the actual constants — e.g. discard could be `PlotIcon.close` or `PlotIcon.trash`; restore could be `PlotIcon.refresh` or `PlotIcon.undo`):

```dart
  Widget _draftTrailingButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPress,
  }) {
    return Builder(
      builder: (context) => FButton(
        onPress: onPress,
        variant: FButtonVariant.ghost,
        style: ghostSizedStyleDelta(
          context,
          iconSize: context.theme.iconSizes.sm,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        ),
        mainAxisSize: MainAxisSize.min,
        child: Icon(icon),
      ),
    );
  }
```

> `ghostSizedStyleDelta` is already imported/used by `pill_grid.dart`'s `_moreButton`; confirm it's importable here (same `lib/widget/` namespace) or replicate the import.

- [ ] **Step 6: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/compose/compose_sections_view.dart
git commit -m "$(cat <<'EOF'
feat(drafts): render Drafts section at top of the new-thread picker

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `PriorityBloc.startFreshDraft` / `resumeDraft`; remove dedup

**Files:**
- Modify: `apps/plot/lib/state/priority.dart`

**Interfaces:**
- Consumes: `isSubstantiveDraftFields` (Task 1); `Thread`, `Note.draft`, `Note.getDraftByActivity` (store).
- Produces:
  - `Future<void> startFreshDraft()` — preserve current substantive working draft (already autosaved), mint a fresh empty one; otherwise reuse-and-clear the skeleton.
  - `void resumeDraft(Thread thread, Note note)` — make an existing draft the working draft.
  - `bool isWorkingDraftSubstantive()` — helper used by the page.

**Verification:** store/emit glue — verified by run-app (Task 10) plus the existing pure predicate test (Task 1).

- [ ] **Step 1: Add a substantive helper + the two methods**

Add the import near the other `package:plot/...` imports in `priority.dart`:

```dart
import 'package:plot/util/draft.dart';
```

Add these methods to `PriorityBloc` near `resetDraft` (line 3271):

```dart
  /// Whether the current working draft holds user content worth keeping.
  bool isWorkingDraftSubstantive() {
    final t = state.draft;
    final n = state.draftNote;
    return isSubstantiveDraftFields(
      title: t.title,
      hasRecipients:
          t.contacts.isNotEmpty || t.groups.isNotEmpty || t.inviteEmails.isNotEmpty,
      hasSchedule: t.at != null || t.on != null,
      body: n.content,
      hasActions: n.actions?.isNotEmpty ?? false,
    );
  }

  /// Starts a brand-new empty working draft on the same priority.
  ///
  /// If the current working draft is substantive it is left intact (it was
  /// autosaved by [updateDraft], so it remains in the Drafts list) and a fresh
  /// draft thread + note replace it in state. If the current draft is an empty
  /// skeleton it is reused and cleared, so abandoned empties never accumulate.
  void startFreshDraft() {
    final current = state.draft;
    if (isWorkingDraftSubstantive()) {
      final fresh = Thread(priority: current.priority, draft: true);
      emit(state.copyWith(
        draft: fresh,
        draftNote: Note.draft(threadId: fresh.id),
      ));
    } else {
      final cleared = current.copyWith(
        title: const Value(null),
        at: const Value(null),
        on: const Value(null),
        duration: const Value(null),
        preview: const Value(null),
        contacts: const Value(null),
        groups: const Value(null),
        inviteEmails: const Value(null),
        teamId: const Value(null),
        icon: const Value(null),
        topicId: const Value(null),
      );
      emit(state.copyWith(
        draft: cleared,
        draftNote: Note.draft(threadId: cleared.id),
      ));
    }
    _draftModified = false;
  }

  /// Loads an existing draft thread + note as the working draft (resume). The
  /// previously-active substantive draft is already autosaved and stays in the
  /// list; an empty skeleton is simply abandoned.
  void resumeDraft(Thread thread, Note note) {
    emit(state.copyWith(draft: thread, draftNote: note));
    _draftModified = true;
  }
```

> `Value` is Drift's `Value<T>` already imported in `priority.dart` (used by `resetDraft`). `Note.draft(threadId:)` is the existing factory.

- [ ] **Step 2: Remove the per-focus dedup deletion**

In `_finalizeDraftInBackground` (lines ~3024-3055) remove the block that archives extra drafts at the same priority — the one that counts `draftRowCount`, fetches `sameIdDrafts`, sorts, and calls `stale.delete()` in a loop. Keep the surrounding draft-note load that follows it. Concretely, delete from the comment `// Clean up duplicate drafts at the chosen draft's priority (legacy).` through the closing brace of the `if (sameIdDrafts.length > 1) { ... }` block and its `profile.mark('drafts deduped (background)');` line. Leave the `// Load the latest active draft note for the draft thread` section intact.

- [ ] **Step 3: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors. (If removing the dedup leaves an unused local like `draftCountQuery`, remove it too.)

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/state/priority.dart
git commit -m "$(cat <<'EOF'
feat(drafts): preserve drafts on fresh-start; add resumeDraft; drop dedup

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `DiscardDraft` / `RestoreDraft` commands

**Files:**
- Modify: `apps/plot/lib/command/thread.dart`

**Interfaces:**
- Consumes: `Thread.delete()` (archive), `Thread.copyWith(archivedAt: Value(null)).save()` (restore).
- Produces: `class DiscardDraft extends Command` and `class RestoreDraft extends Command`, each taking a `Thread`.

**Verification:** `flutter analyze` + run-app (Task 10). Thin wrappers over existing store calls.

- [ ] **Step 1: Add the commands**

Add near the other thread commands in `lib/command/thread.dart` (e.g. after `FinishThread`). Mirror the existing simple-`Command` shape (a `title`, `eventObject`, `eventAction`, `icon`, and a `run` returning a `CommandReturn`). Confirm the exact `CommandReturn`/`CommandDone` symbol used by sibling commands and reuse it:

```dart
/// Discards (archives) a draft thread. Recoverable via "show archived items".
class DiscardDraft extends Command {
  DiscardDraft(this.thread)
      : super(
          title: 'Discard draft',
          eventObject: EventObject.activity,
          eventAction: EventAction.archived,
          icon: PlotIcon.close,
        );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await thread.delete(); // archived_at = now()
    return CommandDone();
  }
}

/// Restores a previously-discarded draft thread (clears archived_at).
class RestoreDraft extends Command {
  RestoreDraft(this.thread)
      : super(
          title: 'Restore draft',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
          icon: PlotIcon.refresh,
        );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await thread.copyWith(archivedAt: const Value(null)).save();
    return CommandDone();
  }
}
```

> Verify against a sibling: `EventAction` enum values (`archived`/`updated` may differ — use ones that exist), `CommandReturn`/`CommandDone` names, and `PlotIcon` constants. If `EventAction.archived` doesn't exist, reuse what `priority_archive_or_merge`/`FinishThread` use. Do not invent enum members.

- [ ] **Step 2: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/thread.dart
git commit -m "$(cat <<'EOF'
feat(drafts): DiscardDraft and RestoreDraft commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Wire the page (`new_thread.dart`)

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

**Interfaces:**
- Consumes: `PriorityBloc.startFreshDraft()` / `resumeDraft()` (Task 7); `DiscardDraft` / `RestoreDraft` (Task 8); `ComposeSectionsView` new params (Task 6); `LocalPreferencesBloc` (`context.read`, `.stream`, `.state.showAllPriorities`).
- Produces: page state `int _draftsRevision`, callbacks `_resumeDraft`, `_discardDraft`, `_restoreDraft`; fresh-draft on entry; pref subscription.

**Verification:** `flutter analyze` + run-app (Task 10).

- [ ] **Step 1: Start fresh on mount**

In `_initializeDraft()` (line 649), before `await _applyQueryParametersToDraft();`, mint a fresh working draft so the page always opens the picker on a clean draft (returning users see saved drafts in the section, not auto-resumed):

```dart
  Future<void> _initializeDraft() async {
    // Every entry to the picker starts a fresh working draft. Any prior
    // substantive draft was autosaved and now appears in the Drafts section;
    // an empty skeleton is reused. See PriorityBloc.startFreshDraft.
    (_priorityBloc ?? context.read<PriorityBloc>()).startFreshDraft();
    await _applyQueryParametersToDraft();
    if (!mounted) return;
    // ... unchanged ...
```

- [ ] **Step 2: Replace `_resetToFreshStart`'s destructive clear**

In `_resetToFreshStart()` (line 513), replace the manual `clearedDraft` + `bloc.updateDraft(...)` block (the part that builds `clearedActions`/`clearedDraft` and calls `updateDraft`) with a single call to `startFreshDraft()`, keeping the rest (the `_pickerSearchController.clear()`, the `setState` resetting `_step`/`_selectedTarget`/etc., `_publishHeaderBack`, `_focusPickerSearch`, and the `ComposeTargetsBloc.refresh()`):

```dart
  void _resetToFreshStart() {
    final bloc = _priorityBloc ?? context.read<PriorityBloc>();

    // Preserve any substantive in-progress draft (it stays in the Drafts
    // section) and start a brand-new empty working draft. Replaces the old
    // reuse-and-clear that destroyed the draft's content.
    bloc.startFreshDraft();

    _pickerSearchController.clear();

    setState(() {
      _step = _ComposeStep.sections;
      _selectedTarget = null;
      _pendingLink = null;
      _selectedRecipient = null;
      _stashedSectionsQuery = '';
      _selectedTwist = null;
      _hadContactsThisSession = false;
      _focusSuggestionOrder = const [];
      _feedbackMode = false;
      _draftsRevision++;
    });
    _publishHeaderBack();
    _focusPickerSearch(_ComposeStep.sections);
    unawaited(
      context.read<ComposeTargetsBloc>().refresh().catchError((
        Object e,
        StackTrace s,
      ) {
        Tracker.captureException(e, s);
      }),
    );
  }
```

- [ ] **Step 3: Add `_draftsRevision` field + pref subscription**

Add the field near the other state fields (e.g. after `_lastFeedbackSeen`, ~line 454):

```dart
  /// Bumped to force [ComposeSectionsView] to reload the Drafts section after
  /// a discard / restore / resume / start-fresh.
  int _draftsRevision = 0;

  /// Subscription to the global archived-visibility preference so the Drafts
  /// section re-queries (and shows/hides archived drafts) when it toggles.
  StreamSubscription<LocalPreferencesState>? _prefsSub;
  bool _showArchivedDrafts = false;
```

In `didChangeDependencies()` (line 584), after `_priorityBloc = context.read<PriorityBloc>();`, set up the subscription once:

```dart
    final prefs = context.read<LocalPreferencesBloc>();
    _showArchivedDrafts = prefs.state.showAllPriorities;
    _prefsSub ??= prefs.stream.listen((s) {
      if (!mounted) return;
      if (s.showAllPriorities == _showArchivedDrafts) return;
      setState(() {
        _showArchivedDrafts = s.showAllPriorities;
        _draftsRevision++;
      });
    });
```

Cancel it in `dispose()` (line 871): add `_prefsSub?.cancel();`.

> Add imports if missing: `dart:async` (`StreamSubscription` — `unawaited` is already imported from it), `package:plot/state/local_preferences.dart`, and the state type for `LocalPreferencesState`.

- [ ] **Step 4: Add the draft callbacks**

Add these methods to the state class (near `_rowMore`, ~line 1367):

```dart
  /// Resume a draft tile: restore it first if archived, load it as the working
  /// draft, and jump to compose.
  Future<void> _resumeDraft(Uuid threadId, bool archived) async {
    final bloc = _priorityBloc ?? context.read<PriorityBloc>();
    final threads = await Thread.get(id: threadId, draft: null, archived: null);
    if (!mounted) return;
    final thread = threads.isEmpty ? null : threads.first;
    if (thread == null) return;
    Thread resumed = thread;
    if (archived) {
      resumed = thread.copyWith(archivedAt: const Value(null));
      await resumed.save();
      if (!mounted) return;
    }
    final note = await Note.getDraftByActivity(threadId) ??
        Note.draft(threadId: threadId);
    if (!mounted) return;
    bloc.resumeDraft(resumed, note);
    setState(() {
      _step = _ComposeStep.compose;
      _selectedRecipient = null;
      _draftsRevision++;
    });
    _publishHeaderBack();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _threadEditorKey.currentState?.focus();
    });
  }

  /// Discard (archive) a draft tile. If it's the active working draft, reset
  /// the picker to a fresh draft.
  Future<void> _discardDraft(Uuid threadId) async {
    final bloc = _priorityBloc ?? context.read<PriorityBloc>();
    final threads = await Thread.get(id: threadId, draft: null, archived: false);
    if (!mounted) return;
    if (threads.isNotEmpty) {
      await context.run(DiscardDraft(threads.first));
      if (!mounted) return;
    }
    if (threadId == bloc.state.draft.id) {
      bloc.startFreshDraft();
      setState(() => _step = _ComposeStep.sections);
      _publishHeaderBack();
    }
    setState(() => _draftsRevision++);
  }

  /// Restore an archived draft in place (without opening it).
  Future<void> _restoreDraft(Uuid threadId) async {
    final threads = await Thread.get(id: threadId, draft: null, archived: true);
    if (!mounted) return;
    if (threads.isNotEmpty) {
      await context.run(RestoreDraft(threads.first));
      if (!mounted) return;
    }
    setState(() => _draftsRevision++);
  }
```

> `context.run(Command)` is the established command-invocation path in this file (see `context.run(ChangeCurrentThread(null))` at ~line 2280). Confirm `Thread.get` accepts `id:`/`draft: null`/`archived: null` (it does — see signature) and `Uuid` is imported (it is, via `Uuid.fromShortString` usage).

- [ ] **Step 5: Pass the new params to `ComposeSectionsView`**

In `_buildTargetPickerStep` (line 2056) add to the `ComposeSectionsView(...)` constructor:

```dart
      draftsRevision: _draftsRevision,
      showArchivedDrafts: _showArchivedDrafts,
      onResumeDraft: (id, archived) => unawaited(_resumeDraft(id, archived)),
      onDiscardDraft: (id) => unawaited(_discardDraft(id)),
      onRestoreDraft: (id) => unawaited(_restoreDraft(id)),
```

- [ ] **Step 6: Verify analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/page/new_thread.dart
git commit -m "$(cat <<'EOF'
feat(drafts): wire Drafts section, fresh-draft entry, discard/restore/resume

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Docs + full verification

**Files:**
- Modify: `apps/plot/docs/updates.md`

- [ ] **Step 1: Add the user-facing updates bullet**

Open `apps/plot/docs/updates.md`. Under the top `## Next release` heading (create it above the latest stamped `## <version>` heading if absent — see the project rules), add a `### Drafts` section (above `### Fixes`) with:

```markdown
### Drafts

- Your drafts are never lost. Start as many as you like — each one is saved and
  shown in a new Drafts list at the top of the new thread screen, so you can pick
  up where you left off. Discard one with the ✕, and turn on "show archived
  items" to see and restore your most recently discarded drafts.
```

- [ ] **Step 2: Full analyze + targeted tests**

Run:
```bash
cd apps/plot && flutter analyze
flutter test test/util/draft_test.dart test/state/draft_summaries_test.dart
```
Expected: analyze clean; both test files PASS.

- [ ] **Step 3: Run-app verification (manual, via the run-app skill)**

Use the `run-app` skill to launch the macOS app against the isolated agent profile, then verify:
1. Open New thread, type a title/body, navigate away (open another thread), reopen New thread → land on the picker, the draft appears at the top under **Drafts**.
2. Start a second draft (type something), press ⌘N → the first draft is still listed; a fresh empty compose starts.
3. Tap a draft tile → it resumes in compose with its content.
4. Click the trailing ✕ on a draft → it disappears from the list (archived).
5. Toggle "show archived items" on → up to 5 discarded drafts appear with a restore icon; tap one → it restores and opens.
6. Confirm an empty (skeleton) draft never appears in the list.

Capture a screenshot of the Drafts section for the record.

- [ ] **Step 4: Finalize**

Run the `/finalize` checklist (lint, backwards-compat, error capture, docs). Then commit:

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/docs/updates.md
git commit -m "$(cat <<'EOF'
docs(drafts): add Next release updates bullet for durable drafts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** never-lose (Task 7 removes dedup + reuse-clear), multiple drafts (Tasks 3/7), return shows most-recent (Tasks 3/9 — fresh picker + drafts listed top), new-thread-again saves + starts new (Task 9 `_resetToFreshStart`→`startFreshDraft`), Drafts section at top with ✕ (Tasks 4/5/6), show-archived ≤5 restorable (Tasks 3/6/9), substantive predicate (Task 1), discard=archive/restore (Task 8). All covered.
- **Local-only drafts:** discard archives (soft), never hard-deletes; both lists filter substantive so empties never surface — consistent with sync rules.
- **Verification reality:** store/UI/bloc integration (Tasks 3,4,5,6,7,8,9) is verified by `flutter analyze` + the run-app pass (Task 10), matching the repo's pure-test convention; pure logic (Tasks 1,2) has full unit tests.
- **Symbol confirmations the implementer MUST make while editing (do not invent):** `PlotIcon.close`/`PlotIcon.refresh`/`PlotIcon.note` constants; `EventAction` enum members for the commands; `CommandReturn`/`CommandDone` symbol; `ActorId.fromUuid`/`Actor.fromCache`/`Group.fromCache` (mirror `searchSections`); `ghostSizedStyleDelta` import in `compose_sections_view.dart`; the exact `ComposePill` leading+name+meta helper to mirror for the `DraftPillData` arm.
- **Concurrent-agent churn:** a sibling session is renaming the show-archived state field (`n`→`showArchived`) in `priority_state.dart`/`thread_state.dart`. This plan deliberately reads the durable `LocalPreferencesBloc.state.showAllPriorities` (not the bloc state field), so it's unaffected. Re-grep line numbers before editing — they may have shifted.
