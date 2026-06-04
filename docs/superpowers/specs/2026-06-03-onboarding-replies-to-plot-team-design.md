# Onboarding replies to Plot Team (announce read-only threads) — design

## Goal

Let a recipient of a read-only onboarding broadcast reply, and have that
reply reach **Plot Team + the thread author only** — never the rest of the
broadcast audience. Concretely, for the global onboarding threads shared to
the "Everyone" announce group:

1. The threads appear authored by an ordinary person (Kris, `kris@plot.day`).
   No group-as-actor machinery.
2. A recipient's reply goes to **Plot Team**.
3. Only **Plot Team** (and the reply's author) can see the reply.

This closes "Gap 1" from the announce-group read-only audit (replies on these
threads currently default to self-only and reach no one) and, as a side
effect, fixes a real pre-existing over-notify bug (scoped notes on any shared
thread currently bump/unread/notify everyone).

## Background — current state

There are **two** onboarding mechanisms; this spec concerns the first:

- **Global announce set** (`welcome`, `priorities`, `connections`,
  `getting-around`, `twists`, `notifications`, `clean-up`): a single shared
  thread row per key, seeded by one-time data migrations
  (`libs/db/migrations/20260414233029_global_onboarding_threads.sql`,
  `…20260417010000_ensure_everyone_group_and_onboarding_filing.sql`),
  `groups = [Everyone]`, `contacts = []`, authored by the seeding user / system
  twist. The "Everyone" group is `type='announce'` with **no admins**, so every
  recipient is a pure read-only viewer.
- **Per-user `welcome-user` thread** (`activate_invited_user`,
  `libs/db/schema/60-functions/activate_invited_user.sql`): one per user,
  `contacts=[user]`, `groups=[Plot Team]` (non-announce), authored by the
  system twist, and it already invites replies ("We read every reply"). This is
  the precedent for `access_groups`/Plot-Team-scoped replies and stays **out of
  scope** here.

Key mechanics that constrain the design:

- **Read-only viewer** = `"user".user_has_thread_write_access(user, thread)`
  is false (`libs/db/schema/90-user-schema/07-user_has_thread_write_access.sql`):
  no linked contact in `thread.contacts`, no membership in a non-announce group
  on the thread, not an admin of an announce group on the thread.
- **Note visibility** (`user.note`, `libs/db/schema/90-user-schema/31-note.sql`):
  a note is visible to a user iff `created_by = user` **OR** both access arrays
  are NULL **OR** `access_contacts && user_contact_ids` **OR**
  `access_groups && user_group_ids` — *and* the user has thread-level
  visibility (`thread.contacts/groups` intersect theirs).
- **Thread visibility** is gated by `thread.contacts`/`thread.groups`, not by
  `thread_priority` alone. To see a thread, a user must be in its contacts or
  one of its groups.
- **Note activity bump** (`update_thread_on_note_change`,
  `libs/db/schema/50-tables/25-note.sql:143`): every non-draft note insert
  bumps the **shared** `thread.last_note_created_at/source_created_at/last_note_seq`,
  **ignoring** `access_contacts`/`access_groups`. The `user.thread` view
  (`…/30-thread.sql`) computes per-user `seq = GREATEST(a.seq, a.last_note_seq,
  tp.seq, ts.seq)`, `updated_at = GREATEST(a.updated_at, a.last_note_created_at,
  …, ts.updated_at)`, and `activity_at = GREATEST(a.last_note_source_created_at,
  …, ts.bumped_at, …)`. So the shared `last_note_*` columns re-emit and re-sort
  the thread for **every** recipient; `thread_state` (`ts.*`) is the per-user
  channel.
- **Unread + push** (`workers/api/src/app/sync/notes.ts`): on note POST a
  background task runs `analyzeNote` or the fallback `markThreadUnreadForOthers`
  (`notes.ts:507`), which resolves recipients by **group membership** and marks
  unread + fires push DOs, **ignoring** the note's access scope.

Consequence today: a scoped reply on a shared broadcast thread bumps, unreads,
and push-notifies the whole audience even though they can't see it. The design
must fix this.

## Invariant

> **A note's re-emit / re-sort / unread / push must reach only the set of users
> who can actually see that note.** Scoped notes (either access array non-NULL)
> never touch the shared `thread.last_note_*` columns; their per-user effects
> ride on `thread_state`, restricted to the note-visible set. Unscoped notes
> (both arrays NULL) keep today's shared-column behavior.

**Note-visible set** for a note `n` on thread `t` = users with thread
visibility on `t` who additionally satisfy: `created_by = user` **OR** both
access arrays NULL **OR** `n.access_contacts && user_contact_ids` **OR**
`n.access_groups && user_group_ids`.

## Design

### 1. Onboarding data (new idempotent migration)

For the seven global onboarding threads:

- `contacts = [Kris's contact]`, and keep note `author_id = Kris's contact` so
  the notes render "from Kris" (requirement 1). Gives Kris write access and
  reply visibility.
- `groups = [Everyone, Plot Team]`. Everyone stays the read-only broadcast
  audience; Plot Team (`key='@plot.team'`, `type='team'`) is added so that
  (a) `access_groups=[Plot Team]` on a reply is a valid subset of
  `thread.groups` (see §2 server rule), and (b) Plot Team gains write access to
  maintain onboarding content.

**No-flood rationale (requirement clarification):** adding Plot Team to
`thread.groups` fires `file_thread_priority_for_group_members`
(`libs/db/schema/95-triggers/23-thread_group_peers.sql`), which inserts both
`thread_priority` and `thread_state` — but **both inserts are `ON CONFLICT …
DO NOTHING`**. Every Plot Team member is already an "Everyone" member (Everyone
= all linked primary contacts in the instance) and already received
`thread_priority` + `thread_state` for all seven shared threads when they
joined Everyone (via `file_thread_priority_on_group_member_change`'s INSERT
branch). So the re-file is a true no-op: no new rows, and existing rows keep
their current (read) state. The only effect is a one-time benign re-sync of the
seven thread rows (the `groups` column changed) to all recipients, with no
unread/feed change.

A Plot Team member's per-user touchpoint as each new user joins remains that
user's `welcome-user` thread (existing, unchanged). A global onboarding thread
only **re-surfaces** for Plot Team when a reply lands, via §3's access-aware
bump — matching "only if a user replies (rare) will the Plot team see that."
(Caveat to verify in the plan: confirm Plot Team members do in fact already
hold `thread_state` rows for the seven threads; if any path leaves a Plot Team
member without one, the `ON CONFLICT DO NOTHING` insert would create an unread
row and surface the thread. The migration can defend against this by deleting
any `thread_state` rows it newly created for Plot Team members on these
threads, leaving them dormant until a reply.)

The migration must be idempotent (guard with `NOT (… = ANY(groups))`) and rely
on the existing `file_thread_priority_for_group_members` trigger
(`libs/db/schema/95-triggers/23-thread_group_peers.sql`) firing on the `groups`
UPDATE. Migrations run on every environment, so this is the durable mechanism;
the global set has no schema-level seed to update.

### 2. Reply scope rule (client default + server enforcement)

The general rule: **when a read-only viewer replies, the note is scoped to all
`thread.contacts` ∪ all non-announce `thread.groups`** (equivalently: all
contacts/groups except announce groups where they aren't an admin). For the
onboarding threads that resolves to `access_contacts=[Kris]`,
`access_groups=[Plot Team]`.

- **Client** (`_readOnlyDefaultShareTargets`, `apps/plot/lib/widget/note_editor.dart`,
  and the save path that builds the `Note`): default a read-only viewer's reply
  to `access_contacts = thread.activeContacts` and
  `access_groups = {non-announce thread.groups}` — reference the **group** via
  `access_groups` rather than expanding members into a contact snapshot, so new
  Plot Team members see past replies. The editor must now pass `accessGroups`
  on save (today it only sets `accessContacts`).
- **Server** (`"user".upsert_note`,
  `libs/db/schema/90-user-schema/85-user-sync-upserts.sql:262`): for a read-only
  viewer, enforce
  - `access_contacts ⊆ (thread.contacts ∪ caller's own linked contacts)`, and
  - `access_groups ⊆ (thread.groups minus announce groups where the caller is
    not an admin)`,
  - keep today's "must be non-NULL" (no public notes), and "cannot edit another
    author's note."
  Reject violations. This makes the rule a real invariant and **closes Gap 3**
  (a viewer can no longer scope a note to the Everyone announce group).

### 3. Access-aware note activity (the leak fix)

- **`update_thread_on_note_change` (DB trigger, `50-tables/25-note.sql`):**
  branch on scope.
  - *Unscoped* (both arrays NULL): bump shared `last_note_*` exactly as today
    (re-emits/re-sorts for everyone — correct, everyone sees it).
  - *Scoped*: do **not** touch shared `last_note_*`. Instead upsert
    `thread_state` for the **note-visible set** — bump `seq`/`bumped_at` so the
    thread re-emits and re-sorts only for those users. The author's row is
    bumped but left read (`read_at` preserved); other visible users get a fresh
    row with `read_at` NULL (unread). Bounded work: scoped notes are rare and
    the visible set is small. Works for all note-creation paths (API, twist,
    connector), so the invariant holds regardless of caller.
- **API note handler (`workers/api/src/app/sync/notes.ts`):** the clean split
  is — **DB trigger owns the per-user re-emit + unread state; the API owns the
  push fan-out.** Concretely:
  - *Scoped notes:* the trigger (above) is the single source of the per-user
    `thread_state` bump + unread for the visible set, so the API must **not**
    separately mark unread (no double-write / no clobbering read state). The API
    only computes the note-visible set and fires the DO-notify loop (`:469`) to
    that set. `markThreadUnreadForOthers` (`:507`) is refactored so its
    recipient computation honors the note's access scope (today it resolves by
    raw group membership); for scoped notes it returns the visible set for
    push without re-marking unread. `analyzeNote` must likewise not mark unread
    / notify outside the visible set.
  - *Unscoped notes:* unchanged from today — the trigger bumps shared
    `last_note_*`, and the API marks unread + pushes to all thread-visible
    users.

### 4. Share-target picker for read-only replies

The recipient picker for a read-only reply should offer `thread.contacts` +
non-announce `thread.groups` (including Plot Team even though the viewer isn't
a member), so the user can narrow the default. Today `Group.getPostable()`
(`apps/plot/lib/store/group.dart:132`) only returns groups the user belongs to;
for the read-only reply case, additionally include the non-announce groups
present on the thread. Announce groups remain excluded.

## Data flow — a recipient replies to "Welcome to Plot!"

1. User X (a read-only Everyone member) types a reply. The editor defaults the
   scope to `access_contacts=[Kris]`, `access_groups=[Plot Team]` (§2 client),
   and saves the note via `POST /sync/notes`.
2. `"user".upsert_note` validates X is a read-only viewer and that the scope is
   within the allowed set (§2 server). Note inserted with `created_by=X`,
   `author_id=X's contact`, the scoped access arrays.
3. `update_thread_on_note_change` sees a scoped note → skips the shared
   `last_note_*` bump; upserts `thread_state` (seq/bumped_at, unread) for the
   note-visible set: Kris + Plot Team members (+ author X, kept read) (§3 DB).
4. The API background task pushes only to that set (§3 API).
5. **Plot Team members and Kris** see "Welcome to Plot!" re-surface with X's
   reply (they already had the thread via Everyone / contacts). **Other Everyone
   recipients** see nothing change — no bump, no unread, no push.
6. X sees their own reply (created_by) via `/sync/notes` + optimistic local
   write.

## Edge cases

- **Kris is also a Plot Team member:** harmless — he sees the reply via both
  `access_contacts` and `access_groups`; dedup is the view's concern.
- **A Plot Team member (write access) replies:** not a read-only viewer, so the
  §2 read-only path doesn't apply; their note can be public or scoped per normal
  rules. A public reply (both arrays NULL) bumps the shared thread for everyone —
  acceptable, since Plot Team is trusted on the thread.
- **Reply to a global thread whose only non-announce group is Plot Team:** scope
  resolves to `[Kris] + [Plot Team]` as intended.
- **Announce thread with no non-announce groups and no contacts (legacy, pre-
  migration):** the default scope is empty → self-only (today's behavior). The
  §1 migration is what gives these threads a real reply target.
- **Connector/twist scoped notes on other shared threads:** §3's DB trigger
  fix applies uniformly, so they too stop over-bumping.

## Non-goals

- No group-as-actor / new `ActorType`; author shows as Kris.
- Not converging the global set into per-user threads (audit Approach C).
- Not changing the per-user `welcome-user` thread.
- Reactions and count-tag leaks (other audit gaps) are out of scope, though
  §3's principle (access-scope-aware fan-out) is the same shape and could be
  reused for the reaction read path later.

## Testing

- **DB (pgTAP / SQL):** `upsert_note` rejects a read-only viewer scoping to the
  Everyone announce group; accepts scoping to Kris + Plot Team; still rejects
  public notes and edits of others' notes. `update_thread_on_note_change`
  leaves shared `last_note_*` untouched for a scoped note and bumps
  `thread_state` only for the visible set; unscoped notes still bump shared
  columns.
- **API (vitest):** posting a scoped reply marks unread + notifies only the
  note-visible users; a public note still notifies all thread-visible users.
- **Migration:** idempotent re-run is a no-op; the seven threads end with
  `groups = [Everyone, Plot Team]` and `contacts = [Kris]`; `types.ts`
  regenerated and committed.
- **Flutter (`flutter analyze` on changed files):** read-only reply default sets
  `accessGroups`; picker offers thread's non-announce groups; announce groups
  hidden.
- **Manual (run-app):** as a non-Plot-Team user, reply to "Welcome to Plot!";
  confirm a Plot Team account sees it and a third non-Plot-Team account does not,
  and that the thread does not re-surface for the third account.

## Backwards compatibility / migration safety

- All schema changes are additive (function `CREATE OR REPLACE`, a data UPDATE
  migration adding array elements). No destructive DDL → expand migration only.
- Old clients that don't send `access_groups` on replies are unaffected; the
  server default/enforcement operates on what they send (and read-only viewers'
  notes were already required to be scoped).
- `note.access_groups` already exists and syncs, so no new synced columns.
