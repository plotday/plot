# Two-step thread creation, target MRU, and thread-level team scoping

**Date:** 2026-06-02
**Owner:** kris@plot.day
**Status:** Draft for review

## Summary

Three coordinated changes to how threads are created and scoped:

1. **Two-step compose flow.** `NewThreadPage` opens on a **target picker** (step 1) — an inline list of "ways to create a thread" reusing the connection-picker content. Choosing a target advances to **step 2**, today's compose surface with the note editor auto-focused, with the **connection field moved above the focus field**. Tapping the connection field in step 2 re-opens the step-1 content in a modal.

2. **Unified target list with global MRU + search.** The step-1 list is every combination of *connector + connection + channel/contacts+groups* plus the Plot-native **Note** / **Chat** variants, ordered by **global** most-recently-used (no focus is chosen first anymore). It can't be fully pre-populated, so combinations are synthesized and search-driven: typing a name surfaces recent combinations for matching correspondents; typing an email surfaces every connection that supports direct-address contacts. Correspondent matching reuses the "authored/replied" filter so send-only addresses don't pollute the list.

3. **Thread-level team scoping.** Every thread carries a team (or Personal). Team membership **gates** visibility, with an explicit exemption for non-team contacts (customers). Leaving a team revokes its threads. This **removes** focus→team assignment and focus default-contacts entirely.

Plot thread types collapse to **Note** (no contacts) and **Chat** (shared); the "Plot" prefix and the dedicated "Task" creation type are dropped.

## Goals

- Pick *what kind of thread and where it goes* first, then write — without choosing a focus up front.
- One ranked, searchable list spanning Plot Note/Chat and every connector target, in global MRU order.
- Make team scope a first-class, enforceable property of every thread so team-leave reliably revokes access, while still allowing external (customer) participants.
- Remove the focus↔team coupling and per-focus default-contacts that the new model makes redundant.

## Non-goals

- No change to the note editor body, attachments, or bottom action bar (the 2026-05-25 compose surface stays; we reorder and re-stage it).
- No change to connector sync, `CreateLinkUserAction` shape, or the channel/link data model beyond adding the `"none"` sharing value.
- No new server-side MRU table — MRU stays client-side (extends `LocalPreferencesBloc`), per the decision to precompute and cache in app state.
- No reintroduction of a "leave team via focus archive" path — that coupling is being removed by the merge-focus change; leaving a team stays a team-management action.
- No descendant/sub-focus handling — focuses are flat (per merge-focus).

## Coordination with in-flight work

- **merge-focus (2026-06-02, Approved).** Assumes flat focuses and removes the leave-team-on-archive branch from `TogglePriorityArchived`. This design lands **after/with** it: it relies on flat focuses and on team-membership being decoupled from focus archival.
- **last-used-connection (2026-05-29).** Its `connectionMru` / `rankConnectionsByMru` / `lastUsedConnectionKey` are the MRU substrate we extend.
- **sharing-models (2026-05-27).** `SharingModel` and its client-side resolution from the primary link are extended with `"none"`.
- **compose redesign (2026-05-25).** The `compose/*` field-row widgets are the step-2 reuse surface.

---

## Part A — Two-step compose flow

### Current state

`NewThreadPage` (`apps/plot/lib/page/new_thread.dart`) renders a single compose surface with rows **Priority → Connection → Contacts → Title → Body** (`_buildComposeSurface`), each row opening a modal (`_selectPriority`, `_openConnectionPicker`, `_openSharedPicker`). The connection field's choices are `ConnectionChoice`s — `PlotThreadChoice` (note/task/chat), `TargetConnectionChoice` (Slack/Gmail/…), `TwistConnectionChoice` (`connection_choice.dart`).

### Step 1 — target picker (inline)

On fresh mount, `NewThreadPage` shows **only** the target picker, rendered **inline** on the page (not in a modal), with the search text field styled to sit naturally at the top of the page rather than as a modal header.

- **Reuse the connection-picker content.** The picker content currently lives inside the connection modal opened by `_openConnectionPicker` (a `SelectModal`-based list of `ConnectionChoice`s). Extract that list+search+keyboard-navigation body into a reusable widget — `TargetPickerList` — that both step 1 (inline) and step 2 (modal) mount. This requires decoupling the list body from the modal shell (`SelectModal` today calls `Modal.pop`, reads `ModalProvider`); the extracted widget takes an `onSelect(target)` callback and an external focus/scroll controller instead.
- **Keyboard navigation is identical** to the modal: ↑/↓ to move the highlight, Enter to choose, type-to-filter. The skill of the existing `ListViewSelector` + `Shortcuts`/`Actions` block moves into `TargetPickerList`.
- Choosing a target calls into the existing apply path (`_applyConnectionChoice` / `_selectTwist` / Plot-variant defaults) and **transitions to step 2**.

### Step 2 — compose

Identical to today's compose surface, with two changes:

- **Field order: Connection → Focus → Contacts → Title → Body.** The connection field moves above the focus field. The focus field sits directly under the connection, pre-selected from the chosen target's roster (carried from step 1); the contacts field sits below it. (Decided 2026-06-02.)
- **Note editor auto-focused** on entry to step 2 (both single- and multi-panel branches), so the user can immediately type.

Field-specific behavior:

- **Connection field** shows the chosen target's label (e.g. `Chat (Acme)`, `Slack (Acme Co) · #general`, `Gmail (kris@plot.day)`). Tapping it **re-opens the step-1 `TargetPickerList` in a modal**; choosing a new target re-applies and stays on step 2.
- **Contacts field** is shown only when the target's sharing model has a roster (see Part C): hidden for **Note** and for `"none"`-sharing connector targets (e.g. Google Tasks). For **Chat** and connector DM/address/`"thread"` targets it behaves as today, pre-filled with any contacts carried from the chosen target.
- **Focus field** is always set to a concrete focus (no Auto-organize). On entry to step 2 it is pre-selected to the **MRU-top** focus for the chosen target's contacts/groups (see Part B). Opening the picker lists focuses in that MRU order. **Auto-organize is removed from this flow.**

### Fresh start

The **New thread** command (`apps/plot/lib/command/thread.dart`, ⌘N) must always remount step 1. The page already remounts per open (route `replace` to `ThreadRoute` after submit), so step state lives in `NewThreadPageState` and initializes to step 1. Any persisted "last target" only pre-highlights within step 1's list; it does **not** skip step 1.

### Files (Part A)

- `apps/plot/lib/page/new_thread.dart` — two-step state machine; field reorder; auto-focus on step 2; connection field re-opens picker.
- `apps/plot/lib/widget/compose/target_picker_list.dart` *(new)* — extracted inline+modal list body.
- `apps/plot/lib/widget/connection_targets.dart`, `connection_choice.dart` — target model extensions (Part B/C).
- The connection modal opener (`_openConnectionPicker` → `ConnectionPickerModal`/`SelectModal`) becomes a thin wrapper that hosts `TargetPickerList` in a `Modal`.

---

## Part B — The target list & MRU

### The target model

A **target** describes how/where a thread is created. It generalizes today's `ConnectionChoice` with team scope and an optional roster:

| Field | Meaning |
|---|---|
| `kind` | `note` \| `chat` \| `connector` \| `twist` |
| `connection` | the `twist_instance` (connector targets/twists); null for Plot Note/Chat |
| `linkType` / `channel` | connector link type + channel (channel connectors) |
| `team` | `null` (Personal) or a `team_id`. Plot Note/Chat: chosen here. Connector: inherited from `connection.team_id`. |
| `contacts` / `groups` | optional roster carried into step 2 (Chat / DM / address targets) |

A target has a stable **signature** used as the MRU key, widening today's canonical keys (`connection_targets.dart`):

```
note   : note:<team|personal>
chat   : chat:<team|personal>[:c=<sorted contact ids>][:g=<sorted group ids>]
twist  : twist:<instance id>
channel: <instance id>|<channel id>|<linkType>
dm/addr: <instance id>||<linkType>|<targets>[:c=<sorted contact ids>]
```

The contact/group component lets "Chat (Acme) with Greg" and "Gmail with Greg" rank as distinct, repeatable combinations.

### Label rules (parentheticals)

Generalize the existing `_scopeSuffix` (`connection_choice.dart:143`):

- **Connector targets** show the **connection account label** (`twist_instance.account_label`) in parentheses **only when the connector has more than one connection** — e.g. `Slack (Acme Co)` vs just `Slack`. The team is *not* shown on connector targets (it's inherited silently).
- **Plot Note/Chat** show the **team / Personal** in parentheses **only when the user belongs to ≥1 team** — e.g. `Chat (Acme)`, `Note (Personal)`. With zero teams they render as bare `Note` / `Chat` (team always Personal/null).
- Channel/contact detail appends after the connector label — `Slack (Acme Co) · #general`, `Gmail (kris@plot.day) · Greg Smith`.

### List composition

The list is the union of, deduped by signature:

1. **Used combinations (MRU)** — derived from the user's recent **authored** threads (the same scan that powers contact MRU in `actor.dart`: `authoredThreadsForSharing`, ordered by `last_note_created_at`). Each thread yields a signature (its source connection+channel via the primary link, or Plot note/chat; its team; its contacts/groups). Deduped, most-recent-first. This is the source of specific combos like `Chat (Acme) with Greg` and `Slack · #general`.
2. **Always-available templates** (even if never used):
   - `Note` and `Chat` for **Personal** and for **each team** the user belongs to.
   - For each connection, a fresh compose template per its link types (e.g. `Gmail thread`, `Google Tasks task`, `Slack thread`). For channel connectors the fresh template surfaces **recently-used channels** inline; the full channel list is reachable via search.
3. **Ordering** — used combinations in global MRU order first, then templates not already represented. Plot Note/Chat and recently-used connector combos float to the top by recency; unused templates fall to the bottom / search.

### Search & dynamic generation

Typing in the step-1 field filters and **synthesizes** beyond the cached list:

- **Plain text** filters cached entries by label (connector, channel, contact name, team).
- **Name match** (e.g. `stacy`) surfaces, for each correspondent matching the text, the **most-recent combinations used with that contact** across connectors that support contact/DM targeting — even if those exact combos aren't in the cached top slice. Correspondents are limited to people the user has **authored/replied** with (reuse the `actor.dart` banding so send-only addresses are excluded).
- **Email input** (matches the email regex) surfaces **every connection whose link types support direct-address contacts**, with any connection previously used for *that address* first, plus an "invite by email" affordance. This lets the user start a fresh thread to a new person on any capable connection.

### Caching & incremental update

Per the decision, the materialized list is **precomputed and cached in app state**, not recomputed per keystroke:

- Extend `LocalPreferencesBloc` (which already owns `connectionMru`) to maintain a **materialized, ranked target list** keyed by signature, combining `connectionMru` recency with the synthesized templates and the authored-thread scan.
- Recompute on the inputs that change it: connections/channels changing, team membership changing, and **new thread creation**. On submit, the existing recording point (the page submit handler / `recordConnectionUsage`) records the **full target signature** (including contacts/groups + team) and **prepends/bumps** it in the cached list so the next New thread reflects it immediately.
- Search runs against the cache plus the dynamic name/email synthesis above.

### Files (Part B)

- `apps/plot/lib/state/local_preferences.dart` — widen MRU key/signature (contacts/groups + team), add a **global** (priority-less) rank, materialized cached list, incremental update on create.
- `apps/plot/lib/store/actor.dart` — reuse authored/replied banding for correspondent matching; expose a helper to map authored threads → target signatures.
- `apps/plot/lib/widget/connection_targets.dart` — signature builder; template synthesis; channel/DM/address capability flags from `LinkTypeConfig`.
- `apps/plot/lib/store/channel.dart` — recently-used channel surfacing.

---

## Part C — Thread types & sharing model

### Note / Chat (drop Task, drop "Plot" prefix)

`PlotThreadKind` collapses to `{ note, chat }` (`connection_choice.dart`):

- **Note** — no contacts. Private to the creator (team-gated if team-scoped). Placeholder "Add a note". Contacts field hidden in step 2.
- **Chat** — shared roster (`thread.contacts`/`groups`). Placeholder "Start a chat".
- Labels drop the prefix: `Note`, `Chat` (plus the team parenthetical per Part B).
- **Task creation type removed.** No "Plot task" target; creating a thread no longer tags the first note as a to-do. To-dos remain fully available **after** creation (the existing `Tag.todo` / active-state toggle on a note) and via connectors (Google Tasks). `plotTask` and its `key`/`label`/defaults are deleted.

### `"none"` sharing model

Extend `SharingModel` (`public/twister/src/tools/integrations.ts`, the 2026-05-27 union) to `"thread" | "channel" | "message" | "none"`:

- `"none"` — the target has **no roster**; no contacts field, no sharing UI. Declared by connectors with no recipient concept (e.g. **Google Tasks**).
- Resolution stays client-side from the primary link's `LinkTypeConfig.sharingModel` (no thread column). Plot **Note** has no link; its no-contacts behavior is driven by the `note` type directly (treated as `"none"` for compose purposes). Plot **Chat** is `"thread"`.
- Twister change requires a **changeset** (`public/.changeset/*.md`, `minor`). Set `sharingModel` on Google Tasks (and any other no-roster connector) to `"none"`.

### Files (Part C)

- `public/twister/src/tools/integrations.ts` — add `"none"`; changeset.
- `public/connectors/*` (Google Tasks, etc.) — declare `sharingModel: "none"`.
- `apps/plot/lib/widget/compose/connection_choice.dart` — drop `task`; rename labels; map Note→no-roster, Chat→thread.
- Compose surface — hide contacts field for no-roster targets.

---

## Part D — Team scoping & permissions

### Data model

Add to `public.thread` (`libs/db/schema/50-tables/24-thread.sql`):

- `team_id bigint NULL REFERENCES public.team(id)` — the owning team; `NULL` = Personal. **Set at creation, immutable thereafter** (mirrors the old locked `priority.team_id`).
- `external_contacts uuid[] NOT NULL DEFAULT '{}'` — the subset of `contacts` exempt from the team-membership gate (non-team / customer participants). Always ⊆ `contacts`.

Add helper `"user".user_team_ids(p_user_id uuid) → bigint[]` (analogous to `user_group_ids`, `06-user_group_ids.sql`): the teams the user currently belongs to via `team_user`.

### Visibility — pure gate + exemption

A user **U** sees a thread iff today's filing/draft/archive rules hold **and**:

```
team_id IS NULL                                  -- personal: unchanged
OR external_contacts && user_contact_ids(U)      -- exempt customer: skips the gate
OR ( (contacts && user_contact_ids(U) OR groups && user_group_ids(U))   -- a recipient/creator
     AND team_id = ANY(user_team_ids(U)) )       -- AND a current member
```

Team membership is a **gate**, not a grant: a member who is *not* a recipient still doesn't see it (keeps `Note (Acme)` private and `Chat (Acme) with Greg` narrow). **`user.thread` already implements a team firewall keyed on the *priority's* `p.team_id`** (`90-user-schema/30-thread.sql:215`); this change **rekeys** it to the thread's own `a.team_id`, adds the `external_contacts` exemption, and drops the now-unused `JOIN priority p`. Filing is unchanged: the existing peer/group filing triggers may over-file non-members, but the view firewall hides those rows (and team-leave revokes them) — today's behavior, just keyed on the thread instead of the priority.

### Point-in-time external classification

When a contact is added to a **team-scoped** thread, classify it **at add-time**: if the contact's linked user is **not** currently a member of `team_id`, add it to `external_contacts` (exempt forever); teammates are left gated. Snapshotting is essential — classifying live ("not currently a member") would let a *removed* teammate flip to exempt and keep access, the exact bug we must avoid.

Implementation: a trigger on `thread` INSERT/UPDATE of `contacts` (and a contact-only path for connector ingest via `upsert_thread`) that, for each newly-added contact on a team thread, appends to `external_contacts` when not a current member. Never re-classifies existing entries. Removing a contact from `contacts` also drops it from `external_contacts` (preserve ⊆). Pure-email contacts and contacts with no linked team-member user are external by definition.

### Team-leave revocation

Replace the focus-archival leave path with thread-level revocation, reusing the established `revoked_at` + `*_redacted` access-loss pattern (`libs/db/AGENTS.md`):

- On `team_user` archive (leave), set `thread_priority.revoked_at = now()` for every thread with `team_id = T` where U was a **gated** recipient (i.e. not exempt via `external_contacts`), so clients hard-delete local copies via `user.thread_redacted`.
- On re-join, un-revoke (`revoked_at = NULL`) the rows that should return.
- The filing triggers (`file_thread_priority_peers`, `populate_thread_priority_for_author`, `file_thread_priority_for_group_members`, `23-thread_group_peers.sql`) gain the team check so non-members aren't filed; external contacts are exempt.

### Connector threads inherit the connection's team

`twist_instance.team_id` already exists ("the team that owns this twist… NULL = personal", `95-twist_instance.sql:8`). Connector-created threads set `thread.team_id` from the creating `twist_instance.team_id` in `upsert_thread` (`90-user-schema/80-upsert_thread.sql`). Their synced attendees run through the same external-classification path.

### Plot Note/Chat team from the picker

User-composed Note/Chat set `thread.team_id` from the step-1 target's team (the `(Personal)`/`(Team)` choice). `finalizeThreadDraft` / the Thread factory (`apps/plot/lib/store/thread.dart`) carries it onto the row.

### Remove focus→team and focus default-contacts

- Drop `priority.team_id` and its triggers (`95-triggers/26-priority_team.sql` inherit/lock/cascade) and the join-time team-focus creation / leave-time archival (`27-team_user_lifecycle.sql`). (Coordinate with merge-focus, which already removes the archive-time leave branch.)
- Drop `priority.default_contacts`, `priority.default_groups`, `priority.default_invite_emails` and their seeding: the Thread factory block (`thread.dart` ~4560-4568) and the `inheritedDefaultShared*` getters (`store/priority.dart`).
- Focus becomes purely organizational and **team-agnostic** — any focus can hold a thread of any team. Filing (`thread.priorityId` / per-user `thread_priority`) is unchanged and orthogonal to team.

### Focus auto-suggest (no Auto-organize)

Step 2 always picks a concrete focus. Rank the user's focuses by MRU **conditioned on the target's contacts/groups** (which focus the user most recently filed threads sharing those same contacts/groups into); pre-select the top, list in that order when opened. With no contacts (Note), rank by overall focus recency. Derived from the same recent-thread scan (focus id + contacts) used for target MRU. `ThreadsBase.autoFileIds` / the Auto-organize entry is removed from this flow. (Server-side auto-classification of *synced connector* threads via `channel.default_priority_id` is unaffected — that's not this manual compose path.)

### Files (Part D)

- `libs/db/schema/50-tables/24-thread.sql` — `team_id`, `external_contacts`.
- `libs/db/schema/50-tables/22-priority.sql` — drop `team_id`, `default_contacts/groups/invite_emails`.
- `libs/db/schema/90-user-schema/30-thread.sql` (+ `thread_redacted`), `06-…user_team_ids.sql` *(new)*, `34-actor.sql` as needed.
- `libs/db/schema/95-triggers/` — external-classification trigger; team-leave revocation; filing-trigger team checks; remove `26-priority_team.sql` and the team-focus lifecycle in `27-team_user_lifecycle.sql`.
- `libs/db/schema/80-upsert_thread.sql` — set `team_id` from creating twist_instance.
- `libs/db/schema/90-user-schema/30-thread.sql` — rekey the team firewall to `a.team_id` + `external_contacts` exemption; expose `team_id` in the SELECT; drop `JOIN priority p`. (No notify/Zod mirror — sync is seq-based.)
- `libs/db/schema/90-user-schema/85-user-sync-upserts.sql` + `80-upsert_thread.sql` — carry/write `thread.team_id` (immutable on update; default from creating `twist_instance.team_id` for connector threads).
- `apps/plot/lib/store/thread.dart`, `priority.dart` — Drift columns + migration (new schema version), carry `teamId`/`externalContacts`, drop priority defaults.

---

## Migration & backfill

1. **Add** `thread.team_id`, `thread.external_contacts` (nullable / defaulted — safe online add).
2. **Backfill `thread.team_id`:**
   - If `created_by` is a `twist_instance` → its `team_id`.
   - Else (user-created) → the team of the focus the thread was filed under at creation (`thread_priority` for the creator → `priority.team_id`), before that column is dropped.
3. **Backfill `external_contacts`:** for each team-scoped thread, mark contacts whose linked user is not a current member of `team_id`. (Best-effort point-in-time snapshot at migration time; acceptable since history can't be reconstructed.)
4. **Drop** `priority.team_id` and `priority.default_*` — expand/contract on production (stop reading in deployed workers/clients first, then drop). Locally a single migration is fine. Per repo rules, never bare-`DELETE` synced rows; the priority columns are a schema change (drop), and a one-shot `UPDATE priority SET updated_at = now()` re-emits rows so clients pick up the new shape.
5. Drop the team-focus lifecycle/locking triggers. Existing team focuses become ordinary personal focuses (their `team_id` removed); their threads keep access via the backfilled `thread.team_id`.
6. Regenerate types (`pnpm types`), bump the Drift schema version with an incremental migration, run `pnpm diff-schema-migrations`.

## Sync & backwards compatibility

- Sync is **seq-cursor based** via the `user.thread` view — there is no `notify_internal_api_for_activity` function or `ActivityItemSchema` Zod schema (the `libs/db/AGENTS.md` reference to them is stale; `rg` finds neither). To surface `team_id` on clients, add it to the `user.thread` SELECT; `external_contacts` stays server-only (firewall input, not needed by clients). The thread sync-upsert path (`85-user-sync-upserts.sql` → `user.upsert_thread`) must carry `team_id` through from the client payload.
- Older clients lacking `team_id`/`external_contacts` awareness still read `contacts`/`groups`; the server-side gate (`user.thread`) enforces correctness regardless, and `thread_priority.revoked_at` drives their cleanup on team-leave. Older clients can't *set* a team → default Personal; acceptable.
- The `"none"` sharing value is additive; clients that don't recognize it fall back to treating the roster as empty (no contacts UI), which matches intent.

## Implementation phases

1. **Twister + connectors (server/contract).** Add `"none"` to `SharingModel`; set Google Tasks (and peers) to `"none"`; changeset; rebuild twister. *(Independent; lands first.)*
2. **DB team scoping.** `thread.team_id` + `external_contacts`; `user_team_ids`; `user.thread`(+redacted) gate; classification trigger; team-leave revocation; filing-trigger team checks; `upsert_thread` team set; notify/Zod mirror; migration + backfill. Drop `priority.team_id`/defaults + lifecycle triggers (coordinate with merge-focus).
3. **Flutter data + types.** Drift columns/migration for `thread.teamId`/`externalContacts`; drop priority defaults; carry team through the Thread factory/finalize.
4. **MRU substrate.** Extend `LocalPreferencesBloc` (widened signature, global rank, materialized cache, incremental update on create); authored-thread → signature mapping; correspondent/email synthesis.
5. **Compose UI.** Drop Task; rename Note/Chat; extract `TargetPickerList`; two-step state machine; step-2 reorder + auto-focus + connection re-open; focus auto-suggest (no Auto-organize); hide contacts for no-roster targets.

Phases 1–3 are contract/data; 4–5 are client UI and can proceed once 1–3 land.

## Testing

- **DB (integration, `workers/api/__tests__` + SQL):** team gate matrix — member recipient sees; non-member recipient doesn't; external customer sees (member or not); leaving the team revokes (revoked_at set, redacted stub emitted); re-join restores; personal threads unaffected; external classification is point-in-time (added-as-member then removed → loses access; added-as-customer → keeps).
- **Flutter (bloc/unit):** widened MRU signature round-trips (contacts/team in key); global rank; cache prepends on create; correspondent search excludes send-only; email input lists address-capable connections; focus auto-suggest picks MRU-top for given contacts.
- **Flutter (manual via `run-app`):** step 1 inline list + keyboard nav matches the modal; selecting advances to step 2 with editor focused; connection field re-opens picker; New thread always starts on step 1; Note hides contacts; team parenthetical only with ≥1 team; connection parenthetical only with >1 connection.
- `flutter analyze` clean; `pnpm lint` clean in `public/twister`, `workers/api`, `libs/db`.

## Open questions / risks

- **`TargetPickerList` extraction** from `SelectModal` is the riskiest UI refactor (modal-shell coupling: `Modal.pop`, `ModalProvider`, reserved close-button space). Mitigation: parameterize selection via callback and host the same widget in both the page and a `Modal`.
- **Template breadth in the base list** — how many fresh connector templates / recently-used channels to show before falling to search. Start conservative (recently-used + one fresh template per connection) and tune.
- **Backfill fidelity** for `external_contacts` on historical threads is best-effort; the point-in-time guarantee only holds strictly for threads created after the change.
- **Immutability of `thread.team_id`** — if users later need to move a thread between teams, that's a separate, explicit re-scope action (with re-classification), out of scope here.
