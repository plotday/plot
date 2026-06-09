# New-thread People list: true MRU + groups

**Date:** 2026-06-08
**Surface:** `NewThreadPage` step-1 sectioned picker (`ComposeSectionsView` / `ComposeTargetsBloc`)
**Status:** Approved design, ready for implementation plan

## Problem

In the new-thread step-1 picker, the **People** section is sourced exclusively
from *authored-thread rosters*:

- `ComposeTargetsBloc.loadSections` builds `people` from
  `dedupePeopleByRoster(scan.threads)`, ordered by
  `buildUsedTargetSignatures` re-ranked through the connection MRU.
- `ComposeTargetsBloc.searchSections` filters those same rosters and
  synthesizes **single-contact** entries via `Actor.get`.

No code path ever queries the `Group` table. Consequences:

1. **Groups never appear in the People list — even when searching.** A group
   surfaces only if it happens to be the roster of a recently-authored thread.
2. **A brand-new group or contact (no thread history) never appears**, and has
   no way to sort to the top of the list.

## Goals

1. **Groups appear in the People list, intermixed with contacts** — including
   via search (search must reach *all* groups, not just recently-used ones).
2. The People list at rest is a **true MRU**: the 8 most-recent rosters (a
   single contact, a multi-contact roster, or a group), ordered purely by a
   recency timestamp. **Both *use* and *creation* set that timestamp to now**,
   so either action bumps the item to the top and everything else slides down.
3. **Creating a group** ("+ Group") and **adding a contact** ("+ Contact") from
   the picker header bump that entity to the top of the MRU.

## Non-goals

- At rest the People list stays **tight** (the 8 most-recent rosters), not a
  full address-book directory. The full set is reachable through search.
- **Edit / rename** does not bump MRU — only *create* / *add* (and messaging,
  which is captured for free by authored threads).
- No Drift schema change and no DB migration.

## Design

### Single recency clock

The People section is one MRU list ordered by a single `recencyMs` per roster.
Two sources feed it, merged by `max`:

- **Use** — messaging a roster writes an authored thread with
  `lastNoteCreatedAt = now`. This is already persisted and even captures
  cross-device activity. We carry that thread timestamp through the scan so it
  participates in ordering.
- **Creation** — a "+ Contact" / "+ Group" with no thread yet records the new
  roster → `now` in an in-memory people-MRU held by `ComposeTargetsBloc`.

`recencyMs(roster) = max(authoredThreadMs(roster) ?? 0, createdMru[roster] ?? 0)`.
Order by `recencyMs` descending, resolve each roster to a pill, take the top
`perSection` (8).

### Persistence: in-memory, session-scoped

The people-MRU created/used map lives **in-memory in `ComposeTargetsBloc`**,
which is app-level (provided in `app.dart`) and therefore long-lived across
picker opens within a session. This is the simplest option and fully satisfies
the true-MRU behavior within a session.

Restart behavior (accepted): *use* always survives restart (it is backed by
persisted threads); a *created-but-never-messaged* group/contact drops out of
the at-rest top-8 after an app restart but remains fully findable via search.

### Components

**`ComposeTargetsBloc` (`lib/state/compose_targets.dart`)**

- New in-memory field `_createdPeopleMru: Map<String /*rosterKey*/, ({RosterKey roster, int ms})>`,
  bounded (~50, evict oldest), keyed by `_rosterKey`.
- New method `recordPersonUsage({contacts, groups, inviteEmails})` — sets the
  roster's entry to `DateTime.now().millisecondsSinceEpoch`, evicting the oldest
  beyond the cap. (Recorded on create/add; messaging needs no call because
  threads already capture it.)
- New **pure, DB-free** helper
  `orderPeopleByRecency(List<({RosterKey roster, int ms})> candidates) → List<RosterKey>`:
  collapses duplicate rosters keeping `max(ms)`, sorts by `ms` desc with a
  first-seen tiebreak. This is the unit-tested core of the true-MRU semantics.
- `ComposeScanThread` gains `recencyMs` (sourced from
  `lastNoteCreatedAt ?? bumpedAt ?? createdAt`). `_scanAuthoredThreads`
  populates it. Pure signature helpers ignore it.
- `loadSections` people building (non-link mode) is rewritten to:
  1. Gather candidate rosters from all scan threads with a non-empty roster
     (`st.contacts`/`st.groups`), each with its thread `recencyMs`.
  2. Merge in `_createdPeopleMru` entries (max ms per roster).
  3. `orderPeopleByRecency(candidates)` → ordered rosters.
  4. Resolve each via `_peopleEntryFor`, drop unresolvable/non-inviteable
     collapses, dedupe on the resolved roster, take `perSection`.
  Link mode is unchanged (people hidden).
- `searchSections` keeps basing off the MRU-ordered `loadSections`
  (`base.people`), then for the synthesized tail adds **group** matches from
  `Group.getPostable(search: query)` alongside the existing **contact** matches
  from `Actor.get`, **intermixed alphabetically by display name**, deduped vs.
  already-surfaced rosters, filling to `perSection`. A second pure helper
  `intermixPeopleByName(List<({String name, ComposePeopleEntry entry})>)`
  performs the case-insensitive sort + roster-dedupe and is unit-tested.

**Commands (`lib/command/contact.dart`, `lib/command/group.dart`, `lib/command/base.dart`)**

- `CommandDone` gains an optional `String? createdId` (default `null`). Using a
  string id (not `Uuid`) avoids importing store types into `command/base.dart`.
- `AddContact` returns `CommandDone(message: ..., createdId: id.toUuid().toString())`.
- `CreateGroup` generates the group UUID explicitly (`id: Value(...)`) instead
  of relying on the `UuidTable` default, and returns it via `createdId`. The id
  passes through `_SaveGroupEdit`'s create branch and `FormModal` unchanged.

**Page wiring (`lib/page/new_thread.dart`)**

- `_addContact`: when `NewContact().run` returns a `CommandDone` with a
  `createdId`, `await bloc.recordPersonUsage(contacts: [Uuid.fromString(id)], groups: [], inviteEmails: [])`
  before returning `true` (so the subsequent reload shows it on top).
- `_addGroup`: same, with `groups: [Uuid.fromString(id)]`.

### Data flow (at rest)

```
authored threads ──(roster, lastNoteCreatedAt ms)──┐
                                                    ├─ max per roster ─ orderPeopleByRecency ─ resolve pills ─ top 8 ─ People section
_createdPeopleMru ──(roster, created/used ms)──────┘
```

### Data flow (search)

```
loadSections(perSection: large).people (MRU-ordered) ─ filter by query ─┐
Group.getPostable(search) ─ group entries ─┐                            ├─ dedupe ─ top 8 ─ People section
Actor.get(search) ─ contact entries ───────┴─ intermixPeopleByName ─────┘
```

## Testing

- **Pure unit tests** (`test/state/compose_sections_test.dart`, no DB):
  - `orderPeopleByRecency`: creation/use bumps a roster above older ones;
    duplicate rosters collapse to `max(ms)`; equal-ms ties keep first-seen
    order; ordering is strictly by `ms` desc.
  - `intermixPeopleByName`: case-insensitive alphabetical interleave of group
    and contact entries; roster-dedupe keeps the first occurrence.
- **`flutter analyze`** clean in `apps/plot`.
- **run-app verification** of the DB-bound paths:
  - A group appears when searching by its name.
  - "+ Group" / "+ Contact" lands the new entity at the top of the People list,
    and a subsequent message to another roster pushes it down.

## Risks / notes

- `dedupePeopleByRoster` is superseded in `loadSections` by the recency
  ordering but remains a documented, unit-tested pure helper (still valid for
  roster dedup); left in place to minimize churn.
- A created contact's optimistic id can be reconciled to a different id on the
  next pull (same-email collapse). The stale pin then fails to resolve and is
  silently dropped — acceptable; the contact still reaches the list once
  messaged or via search.
