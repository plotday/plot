# Groups & Topics — Design

- **Date:** 2026-06-05
- **Status:** Approved design, pre-implementation
- **Scope:** Non-UI functionality — database schema, triggers, API, sync, and client store/read-models. UI widgets are a separate effort and are out of scope here; this doc defines the data and read-models the UI will consume.

## Summary

Plot needs two distinct, related primitives for organizing people and conversations:

- **Group** — a reusable *membership set* (the "who"): a named set of contacts (e.g. "Engineering", "Board"). Usable on any Plot thread, inside topics, and as a recipient shorthand on connector threads.
- **Topic** — a Plot-only *channel* (the "where"): a named stream of threads with its own membership (composed from contacts **and** groups), governance (announce, admins, join/leave), and a routing string so its stream lands in a focus. Slack-style channels.

The defining behavioral rule:

> **Dynamism follows who owns the recipient list.** Plot owns Plot threads and topics, so a group referenced there is tracked *live* — add/remove a member and they gain/lose access everywhere that reference reaches. An external system (Gmail/Slack) owns a connector thread, so a group used to address it is *expanded to contacts once, at send time* (a snapshot) — the external system can't track Plot's live roster.

This reuses Plot's existing `group` machinery (membership → `thread_priority` propagation, the revoked-stub access-loss cleanup, seq-bumps, auto-maintained system groups, the classifier's topic short-circuit) rather than duplicating it. Topics **generalize** that engine; they do not reinvent it.

## Goals

1. Users create named groups from contacts and reuse them across any connection or Plot thread.
2. Groups on Plot threads and inside topics are **live**: a long-running thread shared with "Engineering" adds joiners and drops leavers automatically.
3. Groups expand to a static recipient list when used to create a connector (Gmail/Slack) thread.
4. Users create Slack-style **topics**: add contacts and groups; optionally announce-style; discover, join, leave.
5. All user-created threads in a topic share one routing string so each user can reliably route the topic to a focus.
6. Membership changes propagate to **all** of a topic's threads (join → gain the back-catalog; leave → lose it).
7. Privacy lives on the group: "Plot Users" members can't enumerate the roster or address it; "Engineering" members can. Admins bypass.
8. Migrate the current Everyone broadcast into a renamed **Plot Users** group + a **Plot Updates** topic that members can route and leave.

## Non-Goals (this iteration)

- UI widgets (pickers, channel list, settings panes). Out of scope; we define read-models only.
- Team-scoped topic **discovery** ("browse topics in my team and join"). The schema leaves room for it (`team_id`, join policy) but the discovery surface ships later.
- Explicit per-user "pin this topic to a focus" binding. The stable routing string + the existing learned classifier covers routing now; explicit pinning is a clean later add-on.
- Reworking **Plot Team** (the keyed, addressable-by-everyone feedback group). It keeps its existing `@plot.team` carve-out; revisiting it as a topic is a separate effort.
- Cross-connector behavior changes beyond group→contact expansion at send.

## Use Cases

| # | Scenario | Resolution |
|---|---|---|
| 1 | One "Engineering" group used to send a Gmail thread and to create Plot threads. | Group expands to contacts for Gmail (snapshot); referenced live on Plot threads. |
| 2 | Long-running Plot thread shared with Engineering; people join/leave Engineering. | `thread.groups` live visibility; existing propagation grants/revokes. |
| 3 | Many engineering-related topics that all include the Engineering group. | `topic_group` membership; one group, many topics, all live. |
| 4 | A user is in `#eng-standup` only via Engineering, then leaves Engineering. | Access-path predicate finds no remaining path → revoked-stub cleanup. |
| 5 | Plot Users can't see each other or send; Engineering members can. | Group `privacy` = private vs open; admin bypass. |
| 6 | Plot Updates broadcasts onboarding + updates; a user routes it to a focus and can leave it. | Announce topic over Plot Users; routing string; per-user opt-out. |
| 7 | Opted-out user wants back in. | Topic-entity stays visible while the stream is silenced; opt-out is reversible. |

## Concepts

### Group — the "who"

A group is a *value*: a name plus a set of contact members, plus a **privacy** level and **admins**.

- **open** — members see the roster and can address the group (drop it on a thread or into a topic) and add/remove members and leave. Example: Engineering.
- **private** — only admins see the roster, address it, or manage it; members merely *receive* access when an admin includes them. Example: Plot Users, a team roster.
- **Admins** always bypass privacy (see roster, address, manage).

A group has **no stream of its own** and **no announce/posting governance** — those belong to topics. Privacy is enforced on the group regardless of which container references it, so a private group dropped on a stray direct thread still refuses to reveal its roster or accept a non-admin sender (no To/BCC-style leak).

Reference semantics:

- **Plot thread references a group** (`thread.groups`): live. (Existing behavior — unchanged.)
- **Topic includes a group** (`topic_group`): live; feeds the topic's composed membership.
- **Connector thread addressed to a group**: expanded to contacts at send; no live group reference stored.

### Topic — the "where"

A topic is a Plot-only channel that **owns a stream of threads** and composes membership from contacts and groups:

> effective members = (direct contact members ∪ contacts of included groups) − per-user opt-outs

Governance:

- **announce** (bool) — when true, only admins post; receivers can't post. (Plot Updates.) Privacy of *who's in the topic* still derives from member-group privacy.
- **admins** — manage the topic, post to announce topics, bypass restrictions.
- **join policy** — for now "anyone can join, anyone can leave" (open). The column exists so team-scoped/admin-gated policies can land later.
- **routing string** — every thread in the topic carries the same stable `thread.topic` value, so the classifier routes the whole stream together and the user can move it to a focus.

Privacy **composes upward**: a topic can never reveal the roster of a private member-group. A topic's own roster visibility is bounded by its member-groups' privacy.

### The group ⇄ topic line

|  | Group | Topic |
|---|---|---|
| Answers | "who" | "where" |
| Owns a thread stream | No | Yes (`thread.topic_id`) |
| Membership | contacts | contacts + groups − opt-outs |
| Governance | privacy + admins | announce + join/leave + admins + routing |
| Live where referenced by Plot | Plot threads, topics | its own stream |
| Snapshot | connector sends | n/a |

## Data Model

We **evolve** `group` in place (it keeps its live-on-threads role) and add a **new** `topic` cluster. We do **not** rename `group`.

### `group` (evolved)

Existing columns are retained. Conceptually the table is now purely the membership-set primitive.

- Add `privacy group_privacy NOT NULL DEFAULT 'open'` where `group_privacy` is a new enum `('open','private')`.
- Keep existing `type`, `join_policy` columns for client backwards-compat (old Flutter `GroupRow` reads `type`). They become legacy: server logic switches to `privacy`; `type`/`join_policy` are dual-maintained during the transition and contracted away in a later PR once clients read `privacy`.
- Keep `group_member` (contacts), `group_admin` (users), `auto_maintained`, `key`, `team_id`, `seq`, and all existing triggers (seq-bump, auto-maintain).

Privacy semantics, expressed via `user.group`:

- `member_contact_ids` (roster): admins always; members only when `privacy = 'open'`; otherwise empty.
- `can_address` (new computed column; supersedes `can_post` for groups): admins always; members only when `privacy = 'open'`. Drives "can this user add the group to a thread/topic".

### `topic` (new)

```
topic
  id              uuid PK (uuidv7)
  name            text NOT NULL
  created_by      uuid NOT NULL -> "user"
  team_id         bigint NULL -> team        -- scope; NULL = personal/global
  announce        boolean NOT NULL DEFAULT false  -- only admins post
  join_policy     topic_join_policy NOT NULL DEFAULT 'open'  -- open | admin (future-proofing)
  auto_maintained boolean NOT NULL DEFAULT false  -- system topics (Plot Updates)
  key             text UNIQUE NULL           -- stable id for system topics (e.g. '@plot.updates')
  archived_at     timestamptz NULL
  created_at / updated_at / seq (xid8)        -- same sync plumbing as group
```

Membership / governance tables (mirroring the group pattern, with statement-level seq-bumps onto `topic.seq`):

```
topic_contact      (topic_id, contact_id)            -- direct contact members
topic_group        (topic_id, group_id)              -- included groups (live)
topic_admin        (topic_id, user_id)
topic_member_optout(topic_id, user_id, created_at)   -- per-user "I left"
```

`topic_member_optout` is the load-bearing new mechanism: it subtracts a user from the composed membership for **future** posts (not just existing threads), so an announce topic over an auto-maintained group can't silently re-add someone who left.

### `thread` (changes)

- Add `topic_id uuid NULL -> topic` (single topic per thread — gives an unambiguous routing string; ad-hoc extras still go in `contacts`/`groups`).
- `topic` (existing text routing column) for a topic-thread is derived as `'topic:' || topic_id` so the classifier's topic short-circuit groups the whole stream. (Note the deliberate naming overlap: `thread.topic_id` is the FK to the channel; `thread.topic` remains the freeform routing string.)
- `contacts` / `groups` keep their meaning for ad-hoc extras layered on top of the topic.

### Helper functions / views

- `user.user_topic_ids(user_id) -> uuid[]` — topics the user is an **effective member** of (composed membership minus opt-outs). Mirrors `user_group_ids`.
- `user.topic` view — per-user topic read-model: `is_member`, `is_admin`, `opted_out`, `can_post` (create threads in the stream; gated by `announce` + admin), `can_manage` (edit membership; gated by join policy + admin), `member_count`/`member_contact_ids` (roster, privacy-gated and composition-bounded), `routing` info. **Visible even when opted out** (so the user can rejoin) and when discoverable. (`can_address` is a *group* concept — adding a group to a thread/topic — and does not apply to topics.)
- `user.topic_redacted` — access-loss stub for topics the user fully loses (e.g. a private topic they were removed from), paralleling `user.thread_redacted`.

## Visibility & Membership Semantics

### Thread visibility (`user.thread`)

Extend the visibility predicate with a topic path:

```
WHERE ... AND (
      a.contacts && user_contact_ids(tp.user_id)
   OR a.groups   && user_group_ids(tp.user_id)
   OR (a.topic_id IS NOT NULL AND a.topic_id = ANY(user_topic_ids(tp.user_id)))
)
```

`user_topic_ids` already excludes opt-outs, so an opted-out user fails the topic path (and, if that was their only path, the thread is revoked).

### Access-path predicate (revocation)

The single most important generalization. When a user loses one membership (group_member DELETE, topic_contact/topic_group DELETE, or topic opt-out), the revoke trigger must check whether **any other path** still grants the thread before setting `thread_priority.revoked_at`:

> still a direct contact on the thread? · in another group on the thread? · a direct contact-member of the thread's topic? · in another group included by the thread's topic? · (and not opted out of that topic)

If no path remains → set `revoked_at` (existing redacted-stub cleanup flows to the client). If a path remains → leave filing untouched. This is the same trigger shape as today's `file_thread_priority_on_group_member_change`, with a widened WHERE.

### Propagation triggers (grant/revoke across a topic's stream)

All reuse the existing inline-classify-on-grant / revoked-stub-on-revoke pattern:

- `thread.topic_id` set/changed → file `thread_priority` for the topic's effective members.
- `topic_contact` / `topic_group` insert → grant across the topic's threads; delete → revoke (subject to access-path predicate).
- `group_member` insert/delete → **existing** behavior for `thread.groups` **plus** now propagate to topics that include the group (transitive: group feeds topic membership).
- `topic_member_optout` insert → revoke the user across the topic's threads; delete (rejoin) → re-grant.
- Statement-level seq-bumps so `topic.seq` advances on membership writes (clients re-pull `user.topic`). Same rule as `group` seq-bumps — required for synced computed columns.

### Privacy / roster gating

Enforced in `user.group` / `user.topic`: roster (`member_contact_ids`) and `can_address` honor group `privacy` + admin bypass; a topic's exposed roster is intersected with member-group privacy so a private group's members never leak through a topic.

## Routing (topic → focus)

- A topic-thread's `thread.topic` routing string = `'topic:' || topic_id`, stable across the whole stream.
- The existing classifier `classify_thread_for_user` topic short-circuit (stage 2) already routes all same-`topic` threads to where the user moved one — so moving one Plot Update files the rest, including future ones. No new mechanism required for "route Plot Updates."
- Default focus for an unrouted topic stream is the user's **Inbox/root** (the hardcoded "Using Plot" focus was removed earlier; onboarding already defaults to Inbox).
- **Future:** an explicit `topic → focus` per-user binding table for "pin this topic to a focus" without moving a thread first. Out of scope now.

## Snapshot Expansion for Connector Threads

When a group addresses a connector (Gmail/Slack) thread, the compose/API path **expands the group to its current contacts** and hands those to the connector as recipients; the resulting thread carries the people in `thread.contacts`, with **no live group/topic reference**. Later edits to the group do not reach back into the sent thread. A small server-side helper (`expand_group_contacts(group_id) -> contact_id[]`, privacy/permission-checked) backs this; the connector layer already resolves contacts to per-connection addresses.

## Migration

Ordered, expand-first, backward-compatible. Destructive cleanup (dropping legacy `group.type`/`join_policy`, etc.) is deferred to `migrations-contract/` after clients ship.

1. **Schema expand** — add `group_privacy` enum + `group.privacy`; backfill privacy from current `type` (`announce`/`team` → `private`; `public`/`private` → `open`). Add `topic` cluster + `thread.topic_id` + helper views/functions/triggers. Grant `api`/`readonly` on new tables.
2. **Everyone → Plot Users** — rename the auto-maintained Everyone group's `name` to **"Plot Users"**, set `privacy = 'private'`. Membership maintenance (all linked primary contacts) is unchanged. (Name change only; the row identity and `id` are preserved, so no client strand.)
3. **Create Plot Updates topic** — auto-maintained, `announce = true`, `key = '@plot.updates'`, one `topic_group` row = Plot Users. Admins = Plot team. Add the auto-maintain trigger so it stays a singleton like the Everyone group does.
4. **Point onboarding/updates at Plot Updates** — audit the current onboarding-thread creation path; set `thread.topic_id = <plot_updates>` on new onboarding/update threads (which derives the `topic:` routing string). Backfill existing onboarding threads' `topic_id` and re-file via the standard classify path; default routing = Inbox, user-routable.
5. **Existing user groups** — stay as groups; `privacy` backfilled to `open` (they had visible rosters + member-add). Their `thread.groups` references keep working untouched.
6. **Team groups** — stay as private auto-maintained groups (team rosters). Team *topics* are future work.
7. **Contract (later PR)** — once clients read `privacy`/`user.topic`, drop legacy `group.type`/`join_policy` and any superseded `can_post`-for-groups logic via `migrations-contract/`.

Migration safety: follow `libs/db/AGENTS.md` — never bare-DELETE synced rows (use `archived_at`), bump parent `seq` on child writes, add a one-shot `UPDATE … SET updated_at = now()` so clients re-pull rows that gained view columns.

## API Surface

New / changed (all under the existing Hono app + RPC pattern, `withUserDb`, `safeQuery`, `captureException`):

**Groups** (evolve existing `workers/api/src/app/group.ts`)
- `POST /group` — now takes `privacy` instead of `type`/`joinPolicy` (accept legacy fields for old clients; map to `privacy`).
- `POST /group/:id/members`, `DELETE /group/:id/members`, `POST|DELETE /group/:id/admins` — unchanged shape; permission checks switch to `privacy` (open → members; private → admins).
- `GET /group/:id/expand` (or internal helper) — privacy-checked contact expansion for connector sends.

**Topics** (new `workers/api/src/app/topic.ts` — supersedes the legacy `apiVersion < 3` compat shim, which is removed once safe)
- `POST /topic` — name, announce, team_id?, initial contacts/groups.
- `POST|DELETE /topic/:id/contacts`, `/topic/:id/groups`, `/topic/:id/admins`.
- `POST /topic/:id/join`, `POST /topic/:id/leave` — leave writes `topic_member_optout`; join clears it (or adds `topic_contact` for non-derived members).
- Sending a thread to a topic = thread create/upsert with `topic_id` (see below).

**Thread create/upsert** (`upsert_thread`)
- Accept `topic_id`; when present, derive `thread.topic = 'topic:'||topic_id`, file `thread_priority` for the topic's effective members, and allow ad-hoc extra `contacts`/`groups`.
- Group-addressed connector sends expand to contacts before the connector call (compose/API layer).

**Sync**
- `GET /sync/topics` — paginates `user.topic` by `seq`/`updated_at`, merges `user.topic_redacted` on incremental sync (mirrors `/sync/threads`).
- `GET /sync/groups` — unchanged endpoint; rows gain `privacy`/`can_address`.

## Sync & Client Store

- New read-only `TopicRow` store in `apps/plot/lib/store/` fed by `/sync/topics` (mirrors `group.dart`): `id, name, announce, isMember, isAdmin, optedOut, canPost, canManage, memberContactIds, teamId, key, routing`.
- `GroupRow` gains `privacy` / `canAddress`.
- `ThreadRow` gains `topicId`.
- All additive; old clients ignore unknown columns and still receive topic threads (visible via `user.thread`) without topic chrome.

## Backwards Compatibility

- `thread.groups` live visibility and `user.group` semantics are preserved; topic features are additive.
- `thread.topic` text routing column keeps working; `'topic:'` is just another convention the classifier already tolerates.
- Legacy `group.type`/`join_policy` retained until clients migrate to `privacy`; contract-dropped later.
- Renaming Everyone → Plot Users is a `name` update on a stable row id — no strand.
- Old clients that don't know topics still see topic threads (filed via `user.thread`) with their contacts/groups; they simply can't render the channel.

## Reused vs New Machinery

**Reused (generalized, not duplicated):** `thread_priority` filing + inline-classify-on-grant; `revoked_at` + `user.thread_redacted` access-loss cleanup; statement-level seq-bumps; auto-maintained system-entity pattern (Everyone → Plot Users / Plot Updates); classifier topic short-circuit for routing; contact↔connection address resolution for snapshot expansion.

**New:** `topic` cluster + `topic_member_optout`; `user_topic_ids` / `user.topic` / `user.topic_redacted`; `thread.topic_id`; `group_privacy` + `can_address`; the widened access-path predicate; topic-membership propagation triggers (incl. the transitive group→topic hop); `/sync/topics` + `TopicRow`.

## Testing Strategy

- **pgTAP** (`libs/db/tests/`): privacy roster/address gating (open vs private, admin bypass); topic effective-membership composition incl. opt-out; transitive group→topic grant/revoke; access-path predicate across every path combination (leave one path, keep another); revoked-stub emission + `user.topic`/`user.thread` filtering; routing string derivation; Plot Users/Plot Updates auto-maintenance; seq-bumps advance on membership writes.
- **workers/api vitest**: group/topic RPC permission checks; connector group→contact snapshot expansion; topic send filing; sync pagination incl. redacted merge.
- **Flutter analyze** on changed store files.

## Suggested Build Sequence

1. Schema: `group_privacy` + `group.privacy`; `topic` cluster; `thread.topic_id`; grants. Migration + types + pgTAP for privacy and basic membership.
2. Visibility & propagation: `user_topic_ids`, `user.thread` predicate, access-path predicate, propagation triggers, redacted stub. pgTAP for grant/revoke and access-loss.
3. Routing: topic routing string in `upsert_thread`; classifier verification.
4. API + sync: group `privacy` migration in routes; topic routes; `/sync/topics`; snapshot-expansion helper. vitest.
5. Client store: `TopicRow`, `GroupRow.privacy`, `ThreadRow.topicId`.
6. Data migration: Everyone → Plot Users; Plot Updates topic; onboarding repoint + backfill.
7. Finalize: docs (`features.md`/`updates.md`), contract migration plan for legacy `group` columns.

## Open Questions / Future Work

- **Plot Team** as a topic (feedback channel) — deferred; keeps its `@plot.team` carve-out.
- **Team-scoped discovery** — browse/join topics in a team; needs a discovery surface + join policy enforcement.
- **Explicit topic→focus pinning** — per-user binding table; current learned routing suffices.
- **Nesting depth** — topics include groups (one level). Groups-in-groups is intentionally not supported.
- **Multiple topics per thread** — explicitly rejected (ambiguous routing string). Ad-hoc `contacts`/`groups` cover "add extras".
