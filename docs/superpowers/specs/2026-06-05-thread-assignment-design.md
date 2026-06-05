# Thread Assignment — Design

- **Date:** 2026-06-05
- **Status:** Approved (brainstorming) — ready for implementation planning
- **Topic:** Promote assignment from the link level to the thread level, so any
  thread can be assigned, with best-effort two-way sync to link connectors.

## Goal

Support assigning **any** thread to a contact. When the thread has a link that
supports assignment (e.g. a Linear issue), changes sync best-effort in both
directions with the connector. Otherwise, assignment is a Plot-only concept.
Surface the assignee in the thread row and the thread-page header, give
unassigned threads an "Assign" affordance, provide an assignee picker, and add
an Assignee section to search filters.

## Background — what already exists

Assignment is **already implemented at the link level**, but only for some
connector threads:

- `link.assignee_id` is a real column (`libs/db/schema/50-tables/25-link.sql:36`),
  exposed in `user.link`, and synced to the Flutter Drift store
  (`apps/plot/lib/store/link.dart`). `Link.updateAssignee(link, actorId?)`
  already writes it (`store/link.dart:531`).
- Twister's `Link` has `assignee: Actor | null`; `LinkTypeConfig.supportsAssignee`
  gates it. Linear declares `supportsAssignee: true` and **syncs assignee
  inbound** (external → `link.assignee`).
- The Flutter `SharedCommandButton` (`apps/plot/lib/widget/thread.dart:1034`)
  already renders a clickable assignee `AvatarGroup` (or the `shareAdd`/userPlus
  icon) — but **only** for threads whose primary link is assignment-capable
  (`Thread.resolvePrimaryAssignmentLink`, `store/thread.dart:4764` = earliest
  link with `sharingModel == channel && supportsAssignee == true`).
- The existing assignee picker is `pickLinkAssignee`
  (`apps/plot/lib/widget/link_assignee_picker.dart`), a single-select
  `SelectModal` with a top "Unassigned" option.

**Gaps vs. this design:** no `thread.assignee_id`, so non-connector threads can't
be assigned; no inbound link→thread propagation; outbound thread→connector
write-back isn't wired (Linear's `updateIssue` can set an assignee, but
`onLinkUpdated` only fires for status); the header still uses the overloaded
sharing/assignee widget; there's no "Assign" hover command; and there's no
assignee search filter.

The recent `thread.author_id` work
(`docs/superpowers/plans/2026-06-05-thread-author-id.md`) is the precedent for
the synced-scalar-contact-column plumbing — except `assignee_id` is **mutable**
(no fill-only-when-NULL).

## Decisions

- **Both columns coexist.** `link.assignee_id` stays per-link (a link may be
  non-primary on another thread; multiple links per thread; link assignees shown
  on their own cards). `thread.assignee_id` is the new thread-level source of
  truth, and the **primary** link's assignee change propagates up into it.
- **External wins** on connector threads: inbound sync (primary link → thread)
  overwrites `thread.assignee_id`; user edits write back best-effort and
  reconcile on the next sync.
- **Read-only viewers cannot assign.** Assignment is a single shared field, so it
  follows the same gate as sharing edits (hidden for announce-group / read-only
  threads).
- **Single scalar assignee** per thread (matches `link.assignee` and "the
  avatar").

## Section 1 — Data model & two-way sync

### New columns

- `thread.assignee_id uuid` — nullable, **mutable**. The thread-level source of
  truth. Surface it by:
  - adding it to `user.thread` (and `NULL::uuid` in `user.thread_redacted`);
  - regenerating `libs/db/src/types.ts`;
  - adding a mutable `assigneeId` Drift column (`ActorIdConverter`) in
    `apps/plot/lib/store/thread.dart` with a `schemaVersion` bump + `addColumn`
    migration step.
- `link.supports_assignee boolean NOT NULL DEFAULT false` — set by the API
  runtime in `upsert_link` from the link type's config, evaluating the **same**
  condition the client resolver uses: `sharingModel == 'channel' &&
  supportsAssignee == true`. This is the one signal SQL needs to identify the
  primary assignment-capable link without the connector registry. `upsert_link`
  only sets it when provided (COALESCE-keep on user edits, which never change a
  type property).

### Inbound (connector → thread) — external wins

A statement-level trigger on `link` (fires on insert/update/delete affecting
`assignee_id` / `supports_assignee`) recomputes, per affected thread:

- If the thread has **any** assignment-capable link (`supports_assignee = true`),
  set `thread.assignee_id` = the **earliest-created** such link's `assignee_id`
  (including `NULL` when externally unassigned). This overwrites — external wins.
- If the thread has **no** assignment-capable link, leave `thread.assignee_id`
  untouched (Plot-only, user-managed).

The `UPDATE thread` bumps `thread.seq` (via the existing
`update_seq_and_updated_at` trigger) so clients re-pull — the
`schedule_contact → schedule` bump precedent
(`libs/db/AGENTS.md` "Bump Parent `seq` on Child-Table Changes").

### Outbound (Plot → connector) — best-effort, reuses existing rails

- **Connector thread** (has a primary assignment-capable link): the thread-level
  assignee widget writes the **primary link's** `assignee_id` via the existing
  `Link.updateAssignee` + `POST /sync/links` path. The trigger mirrors it up to
  `thread.assignee_id`, and the existing `links.ts` dispatch fires
  `onLinkUpdated` to the creator connector. Write-back failures are swallowed and
  the next sync reconciles (external wins).
- **Plot-only thread** (no assignment-capable link): the widget writes
  `thread.assignee_id` directly through the existing thread upsert/sync path
  (`upsert_thread` accepts it as a mutable field — no new endpoint). Synced to the
  user's other Plot clients only.

### Backfill migration

Set `thread.assignee_id` from each thread's earliest link that currently has a
non-null `assignee_id` (only assignment-capable connectors ever set it); set
`link.supports_assignee = true` for those links; and bump `thread.updated_at` so
existing clients re-pull the new column (per `libs/db/AGENTS.md` "Also bump on
schema changes that add view columns").

### Loop safety

A connector-thread edit writes the link → trigger mirrors the same value back to
the thread (a no-op-value `seq` bump, no cycle). Plot-only edits write the thread
and never touch links. The trigger only fires on link writes.

## Section 2 — Flutter UI

Split the overloaded `SharedCommandButton` (only two call sites: row trailing
slot `thread.dart:1014`, header end group `page/thread.dart:1376`) into two
reusable widgets and remove it.

### `ThreadAssignee` — reusable assignee widget

Reads `thread.assigneeId` (resolved via `Actor.getOne`/`fromCache` with the same
sync-cache fallback the current code uses).

- **Assigned:** clickable single-avatar `AvatarGroup` (`clickable: true` → the
  existing hover-border highlight). Tap → assignee picker.
- **Unassigned:** an "Assign" affordance — `FaIcon(PlotIcon.assignAdd)` =
  `circleUserCirclePlus` — with an "Assign" tooltip; tap → picker.
- A `showWhenUnassigned` flag controls the empty state: the header passes `true`
  (always shows Assign/Assigned); the row shows the assigned avatar only and
  relies on the hover command for the unassigned case.
- **Read-only threads:** when `thread.isReadOnly`, `ThreadAssignee` renders
  display-only (no tap, no picker) so a read-only viewer still sees an
  externally-set assignee but cannot change it. The header already omits it
  entirely for read-only threads (`if (!readOnly)`); this covers the row's
  persistent avatar on a read-only assigned thread.

### `ThreadSharing` — compact sharing widget

Replaces the sharing AvatarGroup. Renders `userPlus` (no recipients yet) or
`users` + count (sharing), reusing `PickThreadShared.sharedTotalCount` for the
count. Tap routes per `SharingModel` exactly as the current widget decides:
`thread` → editable `PickThreadShared`; `message`/`channel` → read-only
`PickThreadParticipants`; `none` → not shown. **Deliberate simplification:** this
drops the old channel-title text rendering in favor of the spec's users+count.

### Header (`_ThreadActionsRow`)

End group becomes `[if (!readOnly) ThreadSharing(thread), if (!readOnly)
ThreadAssignee(thread, showWhenUnassigned: true), Button.icon(More)]` — sharing,
then Assign/Assigned, then the menu.

### Thread row (`ThreadCommands`)

Replace the link-based `hasAssignment` gate with `isAssigned = thread.assigneeId
!= null`:

- Trailing slot: `if (isAssigned) ThreadAssignee(activity)` — a persistent avatar
  for **any** assigned thread, not just connector threads.
- Hover commands: a new `AssignThread` command, filtered out of the auto hover
  pool (like `PickThreadShared` is) and inserted explicitly **right before the
  More button**, only when `!isAssigned && !readOnly`:
  `[...take(5), Mute, if (!isAssigned && !readOnly) AssignThread, More]`.
  `AssignThread` is also added to `threadCommands` so it appears in the More menu
  (assign/reassign) for keyboard/menu access.

### Assignee picker (`pickThreadAssignee`, generalizing `pickLinkAssignee`)

Single-select `SelectModal` — tapping a row applies it and immediately closes (no
multi-select, no confirm step). **Flat list, no section headers.** Order:

1. **Unassign** (only when currently assigned).
2. The **current assignee** as the first contact, indicated by **colour + font
   weight** (not a leading `done` checkmark).
3. Everyone else, in the connection-aware sort order below.

**Write routing:** connector thread (has primary assignment-capable link) →
`Link.updateAssignee(primaryLink, id)` (rides the existing dispatch); Plot-only
thread → set `thread.assigneeId` directly + save.

**Sort order:**

- *Connector thread* (scoped to the primary link's connection = its `createdBy`
  twist_instance): (1) contacts who are assignees on **other** links in that
  connection, (2) contacts who **authored** links in that connection, (3)
  everyone else — a single sorted list, not sections. Add-ons: current assignee
  first (per above), self near top, most-recently-assigned first as the
  within-group tiebreak (recency). Candidate connection-scoped data comes from
  local Drift queries on `link` (`created_by`, `assignee_id`, `author_id`).
- *Plot-only thread* (no connection — the spec's connection-based sort doesn't
  apply): thread participants (`thread.contacts`) first, then the user's
  most-recently-assigned contacts across Plot, then the rest; self / "assign to
  me" near top.

### Search filter — Assignee section

Add an `assigneeFilter` dimension to the filter model (`PriorityState`) + a
`ToggleAssigneeFilter(actorId)` command, surfaced in `buildFilters`
(`widget/unified_header.dart`) alongside the existing toggles and rendered as
active chips. Candidate options: "Assigned to me", "Unassigned", and the distinct
assignees present in the current scope. The active filter narrows the thread list
by `thread.assigneeId`, applied at the same point the existing tag/icon filters
narrow the agenda/activity list. **To confirm in the plan:** the exact
list-narrowing site (tag/icon filters flow through `PriorityBloc`; the assignee
predicate plugs in there).

## Section 3 — Connector write-back, build order, testing

### Linear connector write-back (`public/connectors/linear`)

`onLinkUpdated` currently early-returns unless `link.status` is set; extend it to
also act on the assignee. The `updateIssue` helper already resolves a Linear user
by the assignee's email and sets/clears `assigneeId`, so this is mostly wiring:
on update, reconcile both status and assignee, best-effort, wrapped in try/catch
with `console.error` (connectors are sandboxed — no PostHog; `console.error`
there is acceptable per project guidance). Because `Link.assignee` already exists
in the Twister SDK, **no `twister/src` change and no changeset** are needed — this
ships as a standalone PR in the `public/` submodule, and the core repo bumps the
submodule pointer after it merges.

### Runtime: persist `link.supports_assignee`

In the link-save path (`workers/api/src/twist/tools/plot/link.ts` /
`thread-helpers.ts` → `upsert_link`), pass `supports_assignee` derived from the
connector's `LinkTypeConfig` (`sharingModel == 'channel' && supportsAssignee`),
available in the connector's dispatch context at save time.

### Build order (for the plan)

1. **DB** — `thread.assignee_id` (+ `user.thread`/redacted, `types.ts`, Drift
   column + `schemaVersion` bump); `link.supports_assignee`; the mirror trigger;
   backfill + `updated_at` bump; expand migration (all additive/nullable → passes
   the Squawk safety gate).
2. **API** — pass `supports_assignee` in link upsert; make `thread.assignee_id` a
   mutable field in `upsert_thread` (the existing `onLinkUpdated` dispatch is
   reused as-is).
3. **Connector** — Linear `onLinkUpdated` assignee write-back (public PR).
4. **Flutter** — `ThreadAssignee` + `ThreadSharing` widgets; header; row +
   `AssignThread` hover command; `pickThreadAssignee` modal; assignee search
   filter; Drift column.

### Testing

- pgTAP for the trigger: primary capable-link change → `thread.assignee`; a
  non-capable link never clobbers a Plot-only assignment; external-wins
  overwrite; unassign mirrors `NULL`; plus backfill verification.
- Worker tests for `upsert_link` capability flag + the `onLinkUpdated` dispatch.
- vitest for Linear's assignee write-back path.
- `flutter analyze` and a `run-app` smoke for the widgets, modal, and filter.

### Finalization

`docs/updates.md` (user-facing: "Assign any thread to someone…") and
`docs/features.md` entries; additive expand-only migration keeps old clients
working (they ignore the new column). The Linear change is a separate `public/`
submodule PR.

## Out of scope

- Multi-assignee threads (single scalar only).
- Deferred connector re-sync sweep to backfill assignees for unassigned-capable
  links not currently carrying an assignee (eventual consistency covers this on
  next sync).
- Assignee write-back for connectors other than Linear (the mechanism is generic;
  only Linear is wired in this pass).
