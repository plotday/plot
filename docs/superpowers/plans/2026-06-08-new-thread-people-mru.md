# New-thread People list: true MRU + groups — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the new-thread step-1 **People** list a true most-recently-used list of contacts *and* groups, where messaging or creating an item bumps it to the top, and search reaches every group.

**Architecture:** The People list is ordered by a single `recencyMs` per roster, merged by `max` from two sources: authored-thread activity (already persisted; carried through the scan) and an in-memory created/used people-MRU on the app-long-lived `ComposeTargetsBloc`. Search synthesizes intermixed group + contact matches alphabetically. Two pure, DB-free helpers carry the unit-tested ordering logic.

**Tech Stack:** Flutter / Dart, `flutter_bloc`, Drift (read-only here — no schema change), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-06-08-new-thread-people-mru-design.md`

**Working directory:** `apps/plot` (all paths below are relative to it unless noted). Worktree: `.claude/worktrees/new-thread-people-mru`.

**Pre-flight (run once before Task 1):**

```bash
cd apps/plot && flutter pub get
flutter test test/state/compose_sections_test.dart test/state/compose_targets_test.dart
```
Expected: existing tests PASS (clean baseline). If `flutter pub get` or analyze reports missing generated files, run `flutter pub run build_runner build --delete-conflicting-outputs` first (no schema change is introduced by this plan, but the baseline tree needs its generated `*.g.dart`).

---

## Reference: key existing symbols

- `RosterKey` — public typedef in `lib/state/compose_targets.dart`:
  `({List<Uuid> contacts, List<Uuid> groups, List<String> inviteEmails})`.
- `_rosterKey(contacts, groups, inviteEmails) → String` — file-private canonical key (sorted), already in `compose_targets.dart`.
- `ComposePeopleEntry({contacts, groups, inviteEmails, display})` — `display` is a `ComposePillData`; `props` are `[contacts, groups, inviteEmails]`.
- `ComposeTargetsBloc._peopleEntryFor(RosterKey r) → ComposePeopleEntry?` — resolves a roster to a pill (group via `Group.fromCache`, single inviteable contact → `ContactPillData`, else `AdHocGroupPillData`).
- `ComposeScanThread({teamId, contacts, groups, primaryLink, priorityId})` — Equatable; constructed in `_scanAuthoredThreads` and in `test/state/compose_targets_test.dart`.
- `Group.getPostable({String? search}) → Future<List<GroupRow>>` — name-filtered; `GroupRow` has `.id` (Uuid), `.name` (String), `.memberContactIds` (List<Uuid>?).
- `Group.getOne(Uuid) / Actor.getOne(ActorId)` — async; populate their static caches on a miss.
- `Actor.fromCache(ActorId) / Group.fromCache(Uuid)` — sync cache reads (miss → null).
- `GroupPillData(GroupRow group, List<Actor> members)` — used by `_peopleEntryFor`.

---

## Task 1: Pure helper `orderPeopleByRecency`

**Files:**
- Modify: `lib/state/compose_targets.dart` (add a top-level function near `dedupePeopleByRoster`)
- Test: `test/state/compose_sections_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/state/compose_sections_test.dart` (inside `void main() {`, after the existing `dedupePeopleByRoster` tests):

```dart
group('orderPeopleByRecency', () {
  const a = '00000000-0000-0000-0000-000000000001';
  const b = '00000000-0000-0000-0000-000000000002';
  const g = '00000000-0000-0000-0000-0000000000a0';

  RosterKey contactRoster(String hex) => (
        contacts: [Uuid.fromString(hex)],
        groups: const <Uuid>[],
        inviteEmails: const <String>[],
      );
  RosterKey groupRoster(String hex) => (
        contacts: const <Uuid>[],
        groups: [Uuid.fromString(hex)],
        inviteEmails: const <String>[],
      );

  test('orders strictly by recency descending', () {
    final out = orderPeopleByRecency([
      (roster: contactRoster(a), ms: 100),
      (roster: groupRoster(g), ms: 300),
      (roster: contactRoster(b), ms: 200),
    ]);
    expect(out.map((r) => r.groups.isNotEmpty ? 'g' : r.contacts.first.toString()),
        ['g', b, a]);
  });

  test('collapses duplicate rosters keeping the max ms', () {
    final out = orderPeopleByRecency([
      (roster: contactRoster(a), ms: 100),
      (roster: contactRoster(b), ms: 250),
      (roster: contactRoster(a), ms: 400), // newer dup of a → a wins overall
    ]);
    expect(out.length, 2);
    expect(out.first.contacts.first.toString(), a);
    expect(out.last.contacts.first.toString(), b);
  });

  test('equal ms keeps first-seen order', () {
    final out = orderPeopleByRecency([
      (roster: contactRoster(a), ms: 100),
      (roster: contactRoster(b), ms: 100),
    ]);
    expect(out.map((r) => r.contacts.first.toString()).toList(), [a, b]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/state/compose_sections_test.dart`
Expected: FAIL — `The function 'orderPeopleByRecency' isn't defined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/state/compose_targets.dart`, add this top-level function immediately after `dedupePeopleByRoster` (keep it near the other pure roster helpers):

```dart
/// Orders people [candidates] into a single true-MRU list. Each candidate is a
/// roster paired with a recency timestamp (epoch ms). Duplicate rosters (the
/// same roster surfaced from more than one source — e.g. an authored thread and
/// the created/used people-MRU) collapse to one entry keeping the **largest**
/// ms. The result is ordered by ms descending; equal-ms ties preserve
/// first-seen order. Pure (no DB) so the MRU semantics are unit-testable.
List<RosterKey> orderPeopleByRecency(
  List<({RosterKey roster, int ms})> candidates,
) {
  // Best ms per roster + first-seen index for a stable tiebreak.
  final bestMs = <String, int>{};
  final firstSeen = <String, int>{};
  final rosterByKey = <String, RosterKey>{};
  var i = 0;
  for (final c in candidates) {
    final key = _rosterKey(c.roster.contacts, c.roster.groups, c.roster.inviteEmails);
    rosterByKey[key] = c.roster;
    firstSeen.putIfAbsent(key, () => i++);
    final existing = bestMs[key];
    if (existing == null || c.ms > existing) bestMs[key] = c.ms;
  }
  final keys = bestMs.keys.toList()
    ..sort((a, b) {
      final byMs = bestMs[b]!.compareTo(bestMs[a]!);
      if (byMs != 0) return byMs;
      return firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  return [for (final k in keys) rosterByKey[k]!];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/state/compose_sections_test.dart`
Expected: PASS (all groups, including the 3 new tests).

- [ ] **Step 5: Commit**

```bash
git add lib/state/compose_targets.dart test/state/compose_sections_test.dart
git commit -m "feat(compose): add orderPeopleByRecency true-MRU helper"
```

---

## Task 2: Pure helper `intermixPeopleByName`

**Files:**
- Modify: `lib/state/compose_targets.dart` (top-level function next to `orderPeopleByRecency`)
- Test: `test/state/compose_sections_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/state/compose_sections_test.dart`:

```dart
group('intermixPeopleByName', () {
  const a = '00000000-0000-0000-0000-000000000001';
  const b = '00000000-0000-0000-0000-000000000002';
  const g = '00000000-0000-0000-0000-0000000000a0';

  ComposePeopleEntry entry(String hex, {bool isGroup = false}) =>
      ComposePeopleEntry(
        contacts: isGroup ? const [] : [Uuid.fromString(hex)],
        groups: isGroup ? [Uuid.fromString(hex)] : const [],
        inviteEmails: const [],
        display: const TopicPillData(''), // a stand-in ComposePillData
      );

  test('interleaves groups and contacts alphabetically, case-insensitive', () {
    final out = intermixPeopleByName([
      (name: 'Zoe', entry: entry(a)),
      (name: 'marketing', entry: entry(g, isGroup: true)),
      (name: 'Bob', entry: entry(b)),
    ]);
    // marketing < Bob < Zoe, case-insensitively → Bob, marketing, Zoe
    expect(out[0].contacts.first.toString(), b); // Bob
    expect(out[1].groups.first.toString(), g); // marketing
    expect(out[2].contacts.first.toString(), a); // Zoe
  });

  test('dedupes by roster, keeping the first occurrence', () {
    final out = intermixPeopleByName([
      (name: 'Bob', entry: entry(b)),
      (name: 'Bob (dup)', entry: entry(b)),
    ]);
    expect(out.length, 1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/state/compose_sections_test.dart`
Expected: FAIL — `The function 'intermixPeopleByName' isn't defined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/state/compose_targets.dart`, add after `orderPeopleByRecency`:

```dart
/// Sorts named people [matches] (contacts and groups together) alphabetically
/// by display name, case-insensitive, and dedupes by roster keeping the first
/// occurrence. Used by search synthesis to intermix contact and group matches
/// rather than segregating them. Pure (no DB).
List<ComposePeopleEntry> intermixPeopleByName(
  List<({String name, ComposePeopleEntry entry})> matches,
) {
  final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])];
  indexed.sort((a, b) {
    final byName = a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase());
    if (byName != 0) return byName;
    return a.$1.compareTo(b.$1); // stable on equal names
  });
  final seen = <String>{};
  final out = <ComposePeopleEntry>[];
  for (final e in indexed) {
    final entry = e.$2.entry;
    final key = _rosterKey(entry.contacts, entry.groups, entry.inviteEmails);
    if (!seen.add(key)) continue;
    out.add(entry);
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/state/compose_sections_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/state/compose_targets.dart test/state/compose_sections_test.dart
git commit -m "feat(compose): add intermixPeopleByName search-synthesis helper"
```

---

## Task 3: Thread the created id back through `CommandDone`

**Files:**
- Modify: `lib/command/base.dart` (add `createdId` to `CommandDone`)
- Modify: `lib/command/contact.dart` (`AddContact` returns id)
- Modify: `lib/command/group.dart` (`CreateGroup` generates + returns id)

- [ ] **Step 1: Add the optional field to `CommandDone`**

In `lib/command/base.dart`, replace the `CommandDone` class (lines ~17-23):

```dart
// Command completed successfully
class CommandDone extends CommandReturn {
  const CommandDone({this.message, this.createdId});

  /// Optional success message to show as a toast
  final String? message;

  /// Optional id of an entity the command just created (e.g. a contact or
  /// group), as a canonical UUID string. Lets a caller react to the new id —
  /// e.g. bump it in the new-thread People MRU — without a separate lookup.
  /// A plain string (not `Uuid`) keeps store types out of `command/base.dart`.
  final String? createdId;
}
```

- [ ] **Step 2: `AddContact` returns the new contact id**

In `lib/command/contact.dart`, in `AddContact.run`, replace the final return:

```dart
    return CommandDone(
      message: 'Contact added',
      createdId: id.toUuid().toString(),
    );
```

(`id` is the `ActorId` generated at the top of `run`; `ActorId.toUuid()` → `Uuid`, `.toString()` → canonical string.)

- [ ] **Step 3: `CreateGroup` generates the id explicitly and returns it**

In `lib/command/group.dart`, in `CreateGroup.run`, generate the id and pass it into the companion, then return it:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final id = Uuid.generate();
    final companion = GroupsCompanion.insert(
      id: Value(id),
      name: name,
      type: 'private',
      joinPolicy: 'member',
      privacy: Value(privacy),
      memberContactIds: Value(memberContactIds),
      // Send the initial member set only when there are members; a brand-new
      // empty group has nothing for the server diff to remove.
      membersDirty: Value(memberContactIds.isNotEmpty),
      isAdmin: const Value(true), // optimistic: creator is admin; reconciled on next pull
      canPost: const Value(true),
      canAddress: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, companion, GroupsBase());
    return CommandDone(message: 'Group created', createdId: id.toString());
  }
```

(`GroupsCompanion` is generated; the `id` column is `Value<Uuid>` because `Groups` mixes in `UuidTable` with a `clientDefault`. Passing `id: Value(id)` overrides that default.)

- [ ] **Step 4: Verify it compiles**

Run: `flutter analyze lib/command/base.dart lib/command/contact.dart lib/command/group.dart`
Expected: No new errors. (If `Value`/`Uuid` are unresolved in `group.dart`, they are already imported via `package:plot/store/store.dart` — confirm the import is present; it is, since the file already uses `GroupsCompanion`/`Uuid`.)

- [ ] **Step 5: Commit**

```bash
git add lib/command/base.dart lib/command/contact.dart lib/command/group.dart
git commit -m "feat(commands): surface created contact/group id via CommandDone.createdId"
```

---

## Task 4: Bloc plumbing — `recencyMs`, created-MRU, cache-safe group resolution

**Files:**
- Modify: `lib/state/compose_targets.dart`

- [ ] **Step 1: Add `recencyMs` to `ComposeScanThread`**

Replace the `ComposeScanThread` constructor + field declarations (near the bottom of the file). Add `recencyMs` as an **optional** field (default `0`) so existing test constructors keep compiling, and add it to `props`:

```dart
class ComposeScanThread extends Equatable {
  const ComposeScanThread({
    this.teamId,
    this.contacts = const [],
    this.groups = const [],
    this.primaryLink,
    required this.priorityId,
    this.recencyMs = 0,
  });

  final BigInt? teamId;
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final ComposeScanLink? primaryLink;
  final Uuid priorityId; // the thread's filed focus (non-null on ThreadRow)

  /// Recency of this thread (epoch ms): `lastNoteCreatedAt ?? bumpedAt ??
  /// createdAt`. Drives the People-list true-MRU ordering. Defaults to 0 for
  /// pure-helper/test construction where recency is irrelevant.
  final int recencyMs;

  @override
  List<Object?> get props =>
      [teamId, contacts, groups, primaryLink, priorityId, recencyMs];
}
```

- [ ] **Step 2: Populate `recencyMs` in `_scanAuthoredThreads`**

In `_scanAuthoredThreads`, where each `ComposeScanThread` is built from `row`, add the `recencyMs` argument:

```dart
      scanThreads.add(ComposeScanThread(
        teamId: row.teamId,
        contacts: contacts,
        groups: row.groups ?? const [],
        primaryLink: _primaryScanLink(links),
        priorityId: row.priorityId,
        recencyMs: (row.lastNoteCreatedAt ?? row.bumpedAt ?? row.createdAt)
            .millisecondsSinceEpoch,
      ));
```

- [ ] **Step 3: Add the in-memory created/used people-MRU + `recordPersonUsage`**

Inside the `ComposeTargetsBloc` class, near the other private state fields (e.g. just below `_searchContext` declarations), add:

```dart
  /// In-memory, session-scoped people-MRU for rosters created/used outside an
  /// authored thread — a "+ Contact" / "+ Group" that has no thread yet. Keyed
  /// by [_rosterKey]; value carries the roster (to resolve a pill) and the
  /// recency ms. Merged (by max ms) with authored-thread recency in
  /// [loadSections] so creation bumps the entry to the top of the People list.
  /// Bounded; oldest entries are evicted past the cap.
  final Map<String, ({RosterKey roster, int ms})> _createdPeopleMru = {};
  static const int _maxCreatedPeopleMru = 50;
```

Add the public recorder method (place it near `recordTarget`):

```dart
  /// Record that the user just created/used a people roster outside an authored
  /// thread (e.g. added a contact or created a group from the picker header).
  /// Bumps it to the top of the People-list MRU. Pre-warms the contact/group
  /// caches so the very next [loadSections] resolves a just-created entity that
  /// hasn't been pulled yet. Idempotent on the roster key.
  Future<void> recordPersonUsage({
    required List<Uuid> contacts,
    required List<Uuid> groups,
    required List<String> inviteEmails,
  }) async {
    final key = _rosterKey(contacts, groups, inviteEmails);
    final now = DateTime.now().millisecondsSinceEpoch;
    _createdPeopleMru[key] =
        (roster: (contacts: contacts, groups: groups, inviteEmails: inviteEmails), ms: now);
    if (_createdPeopleMru.length > _maxCreatedPeopleMru) {
      final oldestKey = _createdPeopleMru.entries
          .reduce((a, b) => a.value.ms <= b.value.ms ? a : b)
          .key;
      _createdPeopleMru.remove(oldestKey);
    }
    // Warm caches so the synchronous _peopleEntryFor resolve below sees a
    // just-created (un-pulled) contact/group. getOne is a cache hit after the
    // first read; swallow not-found (a reconciled/removed id is simply dropped).
    for (final cid in contacts) {
      try {
        await Actor.getOne(ActorId.fromUuid(cid));
      } catch (_) {/* unresolved id is dropped at render time */}
    }
    for (final gid in groups) {
      await Group.getOne(gid);
    }
  }
```

- [ ] **Step 4: Extract a cache-independent group entry builder**

Refactor the group branch of `_peopleEntryFor` into a shared helper so search can build a `ComposePeopleEntry` from a `GroupRow` it already has (no `fromCache` dependency). Add this method to the bloc:

```dart
  /// Build a [ComposePeopleEntry] for a formal group from an already-resolved
  /// [GroupRow], dropping non-inviteable members from the preview. Shared by
  /// [_peopleEntryFor] (cache path) and search synthesis (row path), so a
  /// just-created/un-cached group still resolves in search.
  ComposePeopleEntry _groupPeopleEntry(GroupRow g, RosterKey r) {
    final members = [
      for (final id in (g.memberContactIds ?? const <Uuid>[]))
        Actor.fromCache(ActorId.fromUuid(id)),
    ].whereType<Actor>().where((a) => a.inviteable).toList();
    return ComposePeopleEntry(
      contacts: r.contacts,
      groups: r.groups,
      inviteEmails: r.inviteEmails,
      display: GroupPillData(g, members),
    );
  }
```

Then in `_peopleEntryFor`, replace the group branch body so it delegates:

```dart
    if (r.groups.isNotEmpty) {
      final g = Group.fromCache(r.groups.first);
      if (g == null) return null;
      return _groupPeopleEntry(g, r);
    }
```

- [ ] **Step 5: Verify it compiles**

Run: `flutter analyze lib/state/compose_targets.dart`
Expected: No new errors. (`GroupRow` is already referenced in the file via `Group.fromCache`; `ActorId.fromUuid`/`Actor.getOne`/`Group.getOne` are existing APIs.)

- [ ] **Step 6: Run the existing bloc/pure tests**

Run: `flutter test test/state/compose_targets_test.dart test/state/compose_sections_test.dart`
Expected: PASS (no behavior change yet; `recencyMs` default keeps test constructors valid).

- [ ] **Step 7: Commit**

```bash
git add lib/state/compose_targets.dart
git commit -m "feat(compose): add people-MRU recorder, scan recencyMs, group-row entry builder"
```

---

## Task 5: Rewrite `loadSections` People building to the true-MRU order

**Files:**
- Modify: `lib/state/compose_targets.dart` (`loadSections`)

- [ ] **Step 1: Replace the People-building block**

In `loadSections`, replace the entire `final people = <ComposePeopleEntry>[]; if (!linkMode) { ... }` block (the one that currently builds `rosterTargets` via `buildUsedTargetSignatures` / `rankSignaturesByMru` / `dedupePeopleByRoster`) with:

```dart
    final people = <ComposePeopleEntry>[];
    if (!linkMode) {
      // True MRU: gather candidate rosters with a recency timestamp from two
      // sources, merged by max — authored threads (use, already persisted) and
      // the in-memory created/used people-MRU (a "+ Contact"/"+ Group" with no
      // thread yet). Either source bumps a roster toward the top.
      final candidates = <({RosterKey roster, int ms})>[];
      for (final st in scan.threads) {
        if (st.contacts.isEmpty && st.groups.isEmpty) continue;
        candidates.add((
          roster: (
            contacts: st.contacts,
            groups: st.groups,
            inviteEmails: const <String>[],
          ),
          ms: st.recencyMs,
        ));
      }
      // Warm caches for pinned ids so just-created entities resolve, then add
      // them to the candidate pool.
      for (final e in _createdPeopleMru.values) {
        for (final cid in e.roster.contacts) {
          try {
            await Actor.getOne(ActorId.fromUuid(cid));
          } catch (_) {/* dropped at resolve */}
        }
        for (final gid in e.roster.groups) {
          await Group.getOne(gid);
        }
        candidates.add((roster: e.roster, ms: e.ms));
      }
      // Resolve in MRU order, dropping unresolvable/collapsed rosters, capped.
      final seenRosters = <String>{};
      for (final roster in orderPeopleByRecency(candidates)) {
        final entry = _peopleEntryFor(roster);
        if (entry == null) continue;
        if (!seenRosters
            .add(_rosterKey(entry.contacts, entry.groups, entry.inviteEmails))) {
          continue;
        }
        people.add(entry);
        if (people.length >= perSection) break;
      }
    }
```

> Note: `buildUsedTargetSignatures`, `rankSignaturesByMru`, `_composeTargetForScanThread`, and `dedupePeopleByRoster` remain used elsewhere (`_materializeBaseList`, `lastUsedTargetForRoster`, tests) — do not remove them.

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/state/compose_targets.dart`
Expected: No new errors. If analyze warns that a local (e.g. an now-unused `rosterTargets`) is dead, ensure the entire old block was replaced (it should be — the snippet above is self-contained).

- [ ] **Step 3: Run tests**

Run: `flutter test test/state/compose_sections_test.dart test/state/compose_targets_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/state/compose_targets.dart
git commit -m "feat(compose): order new-thread People list by true MRU (use or creation)"
```

---

## Task 6: `searchSections` — surface all groups, intermixed with contacts

**Files:**
- Modify: `lib/state/compose_targets.dart` (`searchSections`)

- [ ] **Step 1: Replace the contact-synthesis block**

In `searchSections`, replace the final synthesis block — the one that begins with the comment "Synthesize single-contact entries for any matching correspondent…" and loops over `Actor.get(...)` — with a combined, intermixed group + contact synthesis:

```dart
    // Synthesize matching contacts AND groups not already surfaced by a
    // recently-used roster, so search reaches the whole address book. Contacts
    // and groups are intermixed alphabetically by name.
    if (people.length < perSection) {
      final selfIds =
          Actor.getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
      final matched = <({String name, ComposePeopleEntry entry})>[];

      final contacts = await Actor.get(
        types: const [ActorType.user, ActorType.contact],
        search: trimmed,
        inviteable: true,
        primary: true,
      );
      for (final a in contacts) {
        final uuid = a.id.toUuid();
        if (selfIds.contains(uuid)) continue;
        final entry = _peopleEntryFor((
          contacts: [uuid],
          groups: const [],
          inviteEmails: const [],
        ));
        if (entry != null) matched.add((name: a.nameOrEmail, entry: entry));
      }

      // Groups: query by name directly (the People list otherwise never reaches
      // a group the user hasn't recently messaged). Build the entry straight
      // from the row so a just-created/un-cached group still resolves.
      final groupRows = await Group.getPostable(search: trimmed);
      for (final g in groupRows) {
        final entry = _groupPeopleEntry(g, (
          contacts: const [],
          groups: [g.id],
          inviteEmails: const [],
        ));
        matched.add((name: g.name, entry: entry));
      }

      for (final entry in intermixPeopleByName(matched)) {
        if (people.length >= perSection) break;
        if (seenRosters
            .add(_rosterKey(entry.contacts, entry.groups, entry.inviteEmails))) {
          people.add(entry);
        }
      }
    }
```

(`a.nameOrEmail` is non-null `String` on `Actor`; `seenRosters` and `trimmed` are already in scope from earlier in `searchSections`.)

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/state/compose_targets.dart`
Expected: No new errors.

- [ ] **Step 3: Run tests**

Run: `flutter test test/state/compose_sections_test.dart test/state/compose_targets_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/state/compose_targets.dart
git commit -m "feat(compose): search the new-thread People list across all groups, intermixed"
```

---

## Task 7: Page wiring — bump created contact/group in the MRU

**Files:**
- Modify: `lib/page/new_thread.dart` (`_addContact`, `_addGroup`)

- [ ] **Step 1: Update `_addContact` and `_addGroup`**

In `lib/page/new_thread.dart`, replace the two header-button handlers:

```dart
  /// "+ Contact" header button → add a contact. Returns true if added, and
  /// bumps the new contact to the top of the People MRU.
  Future<bool> _addContact() async {
    final result = await NewContact().run(context);
    if (result is CommandDone && result.createdId != null) {
      await context.read<ComposeTargetsBloc>().recordPersonUsage(
        contacts: [Uuid.fromString(result.createdId!)],
        groups: const [],
        inviteEmails: const [],
      );
    }
    return result is CommandDone;
  }

  /// "+ Group" header button → create a group. Returns true if created, and
  /// bumps the new group to the top of the People MRU.
  Future<bool> _addGroup() async {
    final result = await EditGroup().run(context);
    if (result is CommandDone && result.createdId != null) {
      await context.read<ComposeTargetsBloc>().recordPersonUsage(
        contacts: const [],
        groups: [Uuid.fromString(result.createdId!)],
        inviteEmails: const [],
      );
    }
    return result is CommandDone;
  }
```

(`EditGroup()` with no `groupId` runs `_SaveGroupEdit` → `CreateGroup`, whose `CommandDone.createdId` passes through `FormModal` unchanged. `Uuid` and `ComposeTargetsBloc` are already imported in this file; if analyze reports `Uuid` unresolved, it is exported from `package:plot/store/store.dart` which the page already imports.)

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/page/new_thread.dart`
Expected: No new errors.

- [ ] **Step 3: Commit**

```bash
git add lib/page/new_thread.dart
git commit -m "feat(new-thread): bump created contact/group to top of People MRU"
```

---

## Task 8: Full verification, docs, finalize

**Files:**
- Modify: `docs/updates.md` (repo root — user-facing changelog)

- [ ] **Step 1: Full analyze**

Run: `cd apps/plot && flutter analyze`
Expected: No new issues attributable to this change (pre-existing issues, if any, unchanged).

- [ ] **Step 2: Full relevant test run**

Run: `flutter test test/state/compose_sections_test.dart test/state/compose_targets_test.dart test/widget/compose/compose_sections_reactivity_test.dart`
Expected: PASS.

- [ ] **Step 3: Add a user-facing changelog bullet**

In `docs/updates.md` (repo root), add to the top section a plain-language bullet:

```markdown
- The new-thread "People" list now shows your groups alongside contacts, keeps your most recently used people and groups at the top, and surfaces a contact or group at the top the moment you add it. Search now finds any group by name.
```

- [ ] **Step 4: Commit docs**

```bash
git add ../../docs/updates.md   # repo-root docs/updates.md from apps/plot
git commit -m "docs(updates): new-thread People list shows groups + true MRU"
```

- [ ] **Step 5: run-app verification (manual, via the run-app skill)**

This exercises the DB-bound paths that unit tests can't:
1. Open **New thread**. Type a known group's name → it appears in **People** (intermixed with contacts).
2. Header **"+ Group"**, create a group → on return it is **at the top** of People.
3. Header **"+ Contact"**, add a contact → on return it is **at the top** of People.
4. Start a thread with a *different* person → reopen New thread → that person is now on top and the just-created group/contact has moved down (true MRU).

Record the result. Do not claim completion until these are observed (or explicitly deferred by the user).

---

## Self-review notes (already reconciled)

- **Spec coverage:** groups in search (Task 6), true-MRU at rest (Tasks 4–5), create/add bumps to top (Tasks 3 + 7), intermixed (Task 2 + Task 6), in-memory persistence (Task 4). All covered.
- **Type consistency:** `recordPersonUsage`, `orderPeopleByRecency`, `intermixPeopleByName`, `_groupPeopleEntry`, `_createdPeopleMru`, `CommandDone.createdId`, `ComposeScanThread.recencyMs` are named identically wherever referenced.
- **Cache hazard handled:** just-created contact/group resolves via `getOne` pre-warm (Tasks 4/5) and the `GroupRow`-direct path in search (Task 6).
- **No dead code introduced:** `dedupePeopleByRoster` / `buildUsedTargetSignatures` / `rankSignaturesByMru` remain used by `_materializeBaseList` / `lastUsedTargetForRoster` and their tests.
