# Groups & Topics — UI Implementer's Guide

This document is for the agent/developer building the **UI** for groups & topics. The full **data, API, and client-store layers are already implemented** (branch `groups-and-topics`, 5 plans — see `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md` and `docs/superpowers/plans/2026-06-05-…` / `2026-06-06-…`). This guide tells you what exists, what to call, and the one non-trivial thing you still have to wire.

## The model in one paragraph

A **group** is a reusable *set of contacts* (the "who") — e.g. "Engineering". It has a **privacy** (`open` = members see the roster and can use it; `private` = admins only) and admins. A **topic** is a Plot-only *channel* (the "where") that **owns a stream of threads** — e.g. "#eng-standup". Topic membership is composed from **contacts + included groups − per-user opt-outs**, plus governance (announce, admins, join/leave) and a routing string so its stream lands in a focus. A group dropped on a Plot thread or into a topic is tracked **live** (add/remove a member and they gain/lose access everywhere that reference reaches); a group used to address a **connector** thread (Gmail/Slack) is **snapshot-expanded** to contacts at send. Privacy lives on the group and composes upward (a private member-group's roster never leaks through a topic). The old "Everyone" broadcast is now the **Plot Users** group + the **Plot Updates** announce topic over it (users can route or leave Plot Updates).

## What's already on the client (Drift store)

All read-only, synced; mirror the existing group patterns.

- **`apps/plot/lib/store/topic.dart`** — `Topic` helper + `TopicRow` (synced from `/sync/topics`):
  - `Topic.pull()`, `Topic.getOne(id)`, `Topic.watchOne(id)`, `Topic.fromCache(id)`, `Topic.getPostable({search})`.
  - `TopicRow` columns: `name`, `key`, `joinPolicy`, `teamId`, `announce`, `autoMaintained`, `isAdmin`, `isMember`, `optedOut`, `canPost`, `canManage`, `memberContactIds` (+ base `id`/`updatedAt`/`archivedAt`).
  - Registered in `sync_orchestrator.dart` as the `topic` SyncEntity (pulls automatically).
- **`apps/plot/lib/store/group.dart`** — `GroupRow` now has `privacy` (`'open'`/`'private'`) and `canAddress` (bool). `Group.getPostable({search, includeIds})` already exists for the "send to a group" picker. (It currently keys on `is_admin`/`is_member`/`type`; you can switch it to the synced `canAddress` column now that it exists.)
- **`apps/plot/lib/store/thread.dart`** — `ThreadRow.topicId` + `Thread.topicId` accessor (the topic a thread belongs to; synced in). Drift `schemaVersion` is 356.

## API the UI calls (client is already on `X-Plot-API-Version: 4`, so these hit the new entity)

Use the existing API client (`apps/plot/lib/api/api.dart`). All topic routes are version-gated server-side; apiVersion ≥ 3 = the new entity (you're on 4).

**Topics**
- `POST /topic` — create. Body `{ name, announce?: bool, teamId?: number, contactIds?: uuid[], groupIds?: uuid[] }` → `{ id }`.
- `POST|DELETE /topic/:id/contacts` — body `{ contactIds: uuid[] }`.
- `POST|DELETE /topic/:id/groups` — body `{ groupIds: uuid[] }`.
- `POST|DELETE /topic/:id/admins` — body `{ userId: uuid }`.
- `POST /topic/:id/join` — clears the user's opt-out + adds them as a direct member.
- `POST /topic/:id/leave` — opts the user out (universal "leave"; works regardless of how they're a member).
- Server enforces: `auto_maintained` topics (Plot Updates) reject contact/group/admin edits but allow join/leave; non-admins of an `open` topic can manage membership, others get 403.

**Groups**
- `POST /group` — now accepts `privacy: 'open'|'private'` (optional; falls back to type). Existing `name`/`type`/`joinPolicy`/`teamId`/`memberContactIds` still work.
- `POST|DELETE /group/:id/members` — `{ contactIds }`.
- `POST|DELETE /group/:id/admins` — `{ userId }`.
- `GET /group/:id/contacts` → `{ contactIds }` — **snapshot-expand** a group to its members, permission-checked (admin or open-member; else 403). Use this when addressing a **connector** thread to a group.

**Threads in a topic / with groups**
- A Plot thread belongs to a topic via `thread.topic_id`. The server's `upsert_thread` already accepts `topic_id` (or camelCase `topicId`) and derives the routing string. **See the wiring task below.**
- A Plot thread referencing a group (live visibility) uses `thread.groups` (existing behavior, unchanged).

## ⚠️ The one thing you must wire: sending a thread to a topic

The server accepts `topic_id` on `POST /sync/threads`, but **the client's thread push (`ThreadsBase.toBase` in `thread.dart`) does NOT yet serialize `topic_id`** — this was deliberately left for the compose UI.

When the user composes a thread into a topic:
1. Set `topicId` on the new thread row, and include `topic_id` in the create payload sent to `POST /sync/threads` (the `upsert_thread` RPC reads it).
2. **Do NOT blindly add `topic_id` to `toBase` for every thread push.** The server's `upsert_thread` uses `p_thread ? 'topic_id'` — if the key is *present* (even `null`), it overwrites `thread.topic_id`. So a blanket include would wipe `topic_id` to null on every unrelated thread update. Only include `topic_id` in the payload when the compose flow actually set it (i.e., on create-into-a-topic), or guard the server-side CASE if you change the push model.

To **address a group** when composing a *connector* thread (snapshot): call `GET /group/:id/contacts` and add the returned `contactIds` to the thread's `contacts`. For a *Plot* thread referencing a group (live), put the group id in `thread.groups` (existing path).

## Behaviors the UI must respect

- **Opt-out keeps the topic visible.** `Topic.leave()` (POST `/topic/:id/leave`) silences the stream but the topic still appears in `user.topic` with `opted_out = true`, `is_member = false` — so render it as "left, tap to rejoin," not gone. `join` clears it.
- **Posting/using gates:** topic `can_post` (admins always; non-admin members only when not `announce`); group `can_address` (admins; open-privacy members). Use these to enable/disable "post to topic" / "add group" affordances. Announce topics (Plot Updates) show no roster to non-admins (`memberContactIds` empty) and only admins post.
- **Routing a topic to a focus:** every thread in a topic shares one routing string, so the existing "move thread to a focus" mechanism carries the whole stream — no special topic-routing UI is required (moving one topic thread files the rest). An explicit "pin this topic to a focus" affordance is a future add-on, not built.
- **Plot Updates** is the auto-maintained all-users announce topic (key `@plot.updates`); the global onboarding threads now live in it. Users can route it and leave it like any topic.

## Known gaps / out of scope (don't assume these exist)

- **Topic-entity access-loss cleanup is deferred** (Task 7): if a user is *force-removed* from a topic (vs. opting out), their local topic copy can strand — there's no `user.topic_redacted` yet. Opt-out (the normal "leave") keeps the topic visible, so this only bites a force-removal flow, which has no UI. If you build force-removal, coordinate re-enabling Task 7.
- The client→server `topic_id` send (above) is yours to wire.
- Plot-Team-as-topic, team-scoped topic **discovery** (browse/join team topics), and explicit topic→focus pinning are all future work.

## Suggested UI surface (not prescriptive)

A Slack-like **Topics** section (list from `Topic.getPostable` / a full `user.topic` query), each opening its thread stream; topic **create** (name, announce toggle, initial contacts+groups) and **settings** (membership = contacts + groups, admins, join/leave); a **compose picker** offering people + groups + topics as destinations (topic → set `topic_id`; group on a Plot thread → `thread.groups`; group on a connector thread → expand to contacts); **group create** with a privacy (open/private) choice; gate "post"/"add" controls on `can_post`/`can_address`/`can_manage`.

When the UI ships, update `docs/features.md` (new capability) and add a plain-language line to the top of `docs/updates.md`.

## References

- Design spec: `docs/superpowers/specs/2026-06-05-groups-and-topics-design.md`
- Plans: `docs/superpowers/plans/2026-06-05-groups-and-topics-db-foundation.md`, `…-group-privacy.md`, `…-api-sync.md`, `2026-06-06-…-client-store.md`, `…-data-migration.md`
- Server views: `libs/db/schema/90-user-schema/37-topic.sql` (`user.topic`), `35-group.sql` (`user.group` + `can_address`), `30-thread.sql` (`topic_id` visibility)
- Topic RPCs: `libs/db/schema/60-functions/topic.sql`; routes: `workers/api/src/app/topic.ts`, `sync/topics.ts`, `group.ts`
