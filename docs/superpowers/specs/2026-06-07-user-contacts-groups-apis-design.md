# User APIs to add and edit contacts and groups

**Date:** 2026-06-07
**Status:** Approved design, pending implementation plan

## Summary

Add offline-capable, cross-device-syncing user APIs so a user can:

- **Add a contact** — create a new person by name + email, saved to their address book (visible, mentionable, shareable).
- **Edit a contact** — rename only, via a per-user override that never leaks to other users and is sticky against connector re-imports.
- **Manage groups** — create, rename (new; admin-only), and add/remove members, all moved onto the offline-queued sync path.

All operations are offline-capable via the existing `pending`-column write queue, pushed to `/sync/actors` and `/sync/groups`, and synced back to clients through the existing `user.actor` / `user.group` views.

## Scope

In scope:

- Add contact (new person by name + email).
- Edit contact: **name only** (per-user override `user_contact.name`, `source='user'`).
- Group: create, rename (admin-only), add/remove members — all offline-queued.

Out of scope:

- Editing a contact's email, avatar, or removing a contact from the address book.
- Group privacy editing, group delete/archive, group admin management.
- UI wiring (modals/pickers) — this task delivers the API + command/store layer only.
- Rewriting in-flight references to an optimistic temp contact id (e.g. a half-composed thread shared with a not-yet-reconciled new contact). The scope is address-book add/edit, not compose-picker integration.

## Approach

Make the existing `Actors` and `Groups` sync tables **writable**. Both Drift tables already carry a `pending` column but currently sync down only. We add `POST /sync/actors` and `POST /sync/groups` handlers that upsert a single row, reusing the existing offline `pending` → `Store.push()` → `BaseTable.put()` queue. Contacts ride the `Actors` table the UI already reads; a whole group is one syncable row, so create / rename / membership collapse into one row-upsert that the server diffs and authorizes per field.

Rejected alternatives:

- **Dedicated write-only sync entities** — two new Drift tables + pulls + orchestrator entries; more moving parts; diverges from how the UI reads data today.
- **Online-only command endpoints + pull** (what group members do today) — simplest server, no id reconciliation, but **not offline**.

## Server — database RPCs

Location: `libs/db/schema/90-user-schema/`. Additive (new functions + a refactor of `create_group` to share a core). Standard expand migration via `pnpm gen-migration`; regenerate and commit `libs/db/src/types.ts`.

### `user.save_user_contact(p_user_id uuid, p_contact_id uuid, p_email text, p_name text)` → canonical actor row `(id, email, name, …)`

- If `p_email` is non-null: resolve-or-create the global `contact` by email — same email-validation regex and `ON CONFLICT(email)` behavior as `public.upsert_contacts`, but **never writes the global `contact.name`** (user-entered names are per-user only). The resolved contact id wins over `p_contact_id`.
- Else: target the existing `p_contact_id` (rename of a contact already visible to the user).
- Upsert `user_contact(p_user_id, contact_id, linked=<unchanged on conflict / false on insert>, source='user', name=p_name)`. This is the **explicit rename path** that *bypasses* longest-wins and is sticky — the path that `upsert_user_contact_name`'s contract already reserves for "a separate rename API." It must never flip an existing `linked=true` identity row.
- The `set_user_contact_updated_at` trigger bumps `user_contact.seq`; `user.actor` (`GREATEST(uc.seq, a.seq)`) re-emits the row to this user. Creating the `user_contact` row is also what makes a brand-new contact appear in `user.actor` for them.
- Returns the canonical actor row so the client can swap its optimistic id.

### `user.save_group(p_user_id uuid, p_group jsonb)` → `void`

One row-upsert that the server diffs:

- **New `id`** → create: insert `group` with the **client-provided UUID**, creator → `group_admin`, insert `member_contact_ids`. Factor the existing `public.create_group` body to accept a caller-provided id.
- **Existing `id`** → apply deltas:
  - Name change ⇒ **admin-only** (`RAISE EXCEPTION` otherwise).
  - `member_contact_ids` diff ⇒ add/remove reusing the existing `add_group_members` / `remove_group_members` join-policy authorization.
  - Ignore privacy/type changes on update.
- Reject `auto_maintained` groups.
- Member/name writes bump `group.seq` via existing triggers (`schema/95-triggers/24-group_auto_maintain.sql` and the name `UPDATE`), so `user.group` recomputes `is_admin` / `member_contact_ids` / `can_post` / etc.

Groups are client-created UUIDs (consistent with "UUID PKs for client-created rows"), so there is **no group-id reconciliation** — only contacts need it.

## Server — sync endpoints

Location: `workers/api/src/app/sync/`.

- **`POST /sync/actors`** (add `.post` to the existing router in `actors.ts`): accepts one Actors row `{id, type, email, name, …}`. Guards `type === 'contact'` (reject editing twist-instance actors). `withUserDb` → `rpcUser(trx, "save_user_contact", {...})` → `notifyUserSync(c, userId)`. Returns the canonical actor row.
- **`POST /sync/groups`** (add `.post` to the existing router in `groups.ts`): accepts one Groups row `{id, name, privacy, memberContactIds, …}`. `withUserDb` → `rpcUser(trx, "save_group", {...})` → `notifyUserSync(c, userId)`. Returns `{ ok: true }`.
- Both routers are already registered via `sync.route("/", …)` in `index.ts`; adding a `.post` to each existing router needs no new registration.
- The existing online-only `/app/group.ts` endpoints remain for backwards-compat; the client stops using them.

## Client — Flutter

Location: `apps/plot/`.

- **Make `Actors` and `Groups` writable through the queue**: both Drift tables already carry `pending`; wire their `syncEndpoint` so `Store.push()` / `BaseTable.put()` POST dirty rows to `/sync/actors` and `/sync/groups`.
- **Commands** (`lib/command/`):
  - `AddContact(name, email)` — inserts an optimistic `Actors` row (temp UUID, `type='contact'`, `pending`) for instant UI, queued for push.
  - `RenameContact(contactId, name)` — sets `name` + `pending` on the existing `Actors` row.
  - `CreateGroup`, `RenameGroup`, and **migrate** `AddGroupMembers` / `RemoveGroupMembers` from their current direct `api.post('/group/...')` calls to writing `pending` on the `Groups` row so they work offline. The "You're offline, try again" branch goes away.
- All follow the project's command conventions. UI wiring (modals/pickers) is out of scope.

## Contact-id reconciliation

Because a contact's identity is its globally-unique email, the server — not the offline client — owns the final contact id.

1. **Primary**: `POST /sync/actors` returns the canonical actor row; the client applies it (`insertOrReplace`) and, if the canonical id ≠ the optimistic temp id, deletes the temp row.
2. **Safety net**: on the `Actors` down-sync merge, dedupe `type='contact'` rows by email — an incoming canonical row supersedes any local *pending* temp row with the same email. This makes reconciliation resilient even if the POST response is lost.

Rewriting in-flight references to a temp contact id is out of scope (see Scope).

## Testing

- **DB (pgTAP)**: `save_user_contact` creates-by-email / renames / is sticky vs connector longest-wins / never touches a linked identity / surfaces in `user.actor`. `save_group` create-with-client-id / rename-admin-only / member add-remove authz / rejects `auto_maintained`.
- **Workers (vitest, TS↔PG)**: `POST /sync/actors` guards `type`, returns canonical row, reconciliation id-swap; `POST /sync/groups` create/rename/membership + authz error mapping.
- **Flutter**: `flutter analyze`; command/store unit tests for optimistic insert + email-keyed merge dedupe.

## Risks / notes

- **Contact-id reconciliation** is the main technical risk; mitigated by the two-layer strategy above.
- **Backwards compat**: `/app/group.ts` endpoints are retained; no fields removed. New columns/functions are additive (expand migration; contract not required).
- **Per-user name isolation**: `save_user_contact` must write only `user_contact.name`, never `contact.name`, or a user's chosen name would leak to other viewers.
- **Seq bumps**: rely on existing triggers (`set_user_contact_updated_at`, group member/name bumps) so `user.actor` / `user.group` re-emit. Verify in pgTAP.
