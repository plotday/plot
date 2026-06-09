# Use groups with email-accepting connections

**Date:** 2026-06-09
**Status:** Approved design

## Problem

Plot "groups" (reusable sets of contacts) can be addressed on a Plot thread, but
they cannot be used with email-accepting connections such as Gmail:

1. **Compose UI**: When a group is selected as a recipient, the connection
   picker (compose step 2) hides every email-accepting connection, so the user
   can't choose to send the thread via Gmail at all.
2. **Dispatch**: Even if a thread carrying a group reached an email connector,
   the create-link dispatch path builds the connector's recipient list purely
   from `thread.contacts` and ignores `thread.groups`, so no group member would
   receive the email.

## Goal

Let a user address a thread to a group and send it through an email-accepting
connection (Gmail). The group is **expanded to its member email contacts at the
moment recipients are handed to the connector** — ephemerally. The thread keeps
referencing the group (`thread.groups` is unchanged); members are never written
back onto `thread.contacts`.

## Guiding invariant

**Never offer a connection for a group that would silently drop a member.**
A connection may only be offered for a group when every member is reachable on
it. For this first iteration the only reachability type is **email**, and we
make the guarantee *structural* by requiring every group member to have an
email address (see "Group membership restriction" below). With that guarantee,
every member is reachable both by email-accepting connectors and by Plot itself
(Plot notifies non-users by email), so no send silently drops anyone.

This is deliberately the simplest reliable starting point. The general model —
"offer connection X for a group iff every member is reachable on X" — is a
future generalization (e.g. Slack/LinkedIn: offer iff every member has a handle
on that platform). When that lands, the email-only membership rule is loosened
into a per-platform reachability model.

## Non-goals

- No Slack/LinkedIn (or other `contacts`-type DM) support for groups yet. The
  compose change is scoped to `addresses`-type (email) connections. Those DM
  connectors often expose a handle with no email behind it, so honoring the
  invariant for them requires the future per-platform reachability model.
- No persisting of group members onto the thread (expansion is in-memory only).
- No schema migration of existing groups. The groups feature is not yet released
  (contacts/groups work is on local `main`, the Groups & Topics PR is still
  open), so there is no production group data to clean up.
- Reply handling on existing email threads is untouched — replies go to the
  message's already-known participants.

## Design

Three coordinated changes: a group-membership email restriction (the structural
guarantee), the compose picker offering email connections for groups, and the
server expanding the group to member emails at dispatch.

### Part 1 — Group membership restriction (the structural guarantee)

Every member of a group must have an email address. Enforced in the
**user-facing group mutations only**, never as a blanket `group_member` CHECK
constraint or trigger — trigger-driven auto-maintained groups (team
"Everyone"-style groups, "Plot Users") populate `group_member` directly and must
not be at risk. Those auto groups only ever add Plot users, who always have an
email, so the guarantee still holds for them without any enforcement on the
auto-maintenance path.

**Server** (`libs/db/schema/`):

- `user.save_group` (`90-user-schema/84-save-group.sql`): before inserting
  members, reject the call if any member contact has a null `email`
  (`RAISE EXCEPTION`). Members are referenced by `contact_id`, so the check
  joins `contact`.
- Audit the other user-reachable member-adding functions in
  `60-functions/group.sql` — `public.add_group_members` and
  `public.create_group` — and apply the same validation to any that are
  reachable from user input (via an API route / RPC). A small shared helper
  (e.g. `assert_group_members_have_email(member_ids uuid[])`) keeps the rule in
  one place. `remove_group_members` and the auto-maintain triggers are not
  touched.

**API** (`workers/api/src/app/sync/groups.ts`): the validation surfaces as a
clean error from the RPC; the route propagates it (no silent swallow) so the
client can show a meaningful message.

**Flutter UI** (group member picker): in the create/edit-group flow
(`apps/plot/lib/command/group.dart`, `FormShareSelect` / `PickShared` in
`apps/plot/lib/widget/form.dart`), contacts without an email are disabled (or
hidden) in the candidate list with a short hint ("No email address"). The
client already loads each candidate's `Actor` (which carries `email`), so the
check is local. If a stale/invalid member slips through, the server error is
shown rather than a generic failure.

### Part 2 — Compose: offer email connections when a group is selected

**File:** `apps/plot/lib/state/compose_targets.dart`,
`connectionsForRoster(...)` (~line 1127), the DM-connector loop at ~line 1144.

Today:

```dart
if (groups.isEmpty) {
  for (final t in ctx.createTargets.where((t) => t.isDmType)) {
    options.add(ComposeTarget.connector(
      t,
      connectionCount: ctx.connectionCount(t),
      contacts: contacts,
    ));
  }
}
```

`isDmType` (`apps/plot/lib/widget/connection_targets.dart`) is
`compose.targets == 'contacts' || compose.targets == 'addresses'`.

Two edits:

1. **Stop skipping DM connectors when a group is present, but offer only
   email.** When `groups.isNotEmpty`, include only `addresses`-type connectors;
   continue excluding pure `contacts`-type DMs (Slack/LinkedIn — deferred). When
   `groups.isEmpty`, behavior is exactly as today (all `isDmType`). Concretely
   the predicate becomes
   `t.isDmType && (groups.isEmpty || t.compose.targets == 'addresses')`, and the
   surrounding `if (groups.isEmpty)` guard is removed.
2. **Carry the group onto the target.** Pass `groups: groups` to
   `ComposeTarget.connector(...)` (it already accepts and signature-includes
   `groups`). This lands the group in `thread.groups` when the target is picked,
   so Part 3 has something to expand.

No per-member email check is needed in the picker: Part 1 guarantees every
group member has an email, so any group is safe to offer email connections.

### Part 3 — Server: expand group → member emails at dispatch

**File:** `workers/api/src/app/sync/threads.ts`, inside the existing
`create_link` dispatch block (the `c.executionCtx.waitUntil(...)` at ~line 886).

Today the block reads `threadData.contacts` into `dispatchContactIds`
(lines 879–881), resolves those to `{id,email,name}` rows (lines 894–921,
excluding contacts linked to the author), and passes them as `draft.contacts`.
It never reads `threadData.groups`.

Change:

1. Snapshot `threadData.groups` into `dispatchGroupIds: string[]` alongside
   `dispatchContactIds`.
2. Inside the `waitUntil`, before the contact-resolution query, expand each
   group to member contact IDs via the existing
   `expand_group_contacts(p_user_id = userId, p_group_id = groupId)` RPC
   (`libs/db/schema/60-functions/expand_group_contacts.sql`, gated by
   `user_can_address_group`). Per-group `try/catch`: skip a group that throws,
   never dropping the rest of the send; report genuinely unexpected errors via
   `c.var.tracker.captureException`.
3. Merge the expanded member IDs with `dispatchContactIds` into a deduped set
   and feed the union into the existing `.where("c.id", "in", <union>)`
   resolution. The existing author-exclusion filter and `integrations.ts`
   email resolution (`contact_external_account` → `contact.email` fallback,
   `addresses` target) apply unchanged.

`thread.groups`/`thread.contacts` are not modified — expansion lives only in the
in-memory `draft.contacts`. The "member without an email is dropped" branch
remains as a defensive safety net; Part 1 makes it unreachable in practice.

## Data flow (Gmail example)

1. User addresses a new thread to group "Marketing" (every member has an email,
   per Part 1) → `groups = [Marketing]`, `contacts = [you]`.
2. Connection picker (`connectionsForRoster`) now lists Gmail; its
   `ComposeTarget` carries `groups = [Marketing]`.
3. User picks Gmail and sends → thread created with `thread.groups =
   [Marketing]` and a `create_link` requested for the Gmail connection.
4. `threads.ts` dispatch expands `Marketing` → member contact IDs, merges/dedupes
   with direct contacts, resolves to emails (author excluded), passes them as
   `draft.contacts`.
5. `integrations.ts` resolves `draft.contacts` → `draft.recipients`
   (`addresses` target); the Gmail connector sends `To:` the member emails.

## Testing

- **Server — membership** (`workers/api` integration test, TS↔Postgres harness):
  `save_group` rejects a group containing an emailless member; accepts a group
  whose members all have email; the error propagates cleanly through
  `POST /sync/groups`.
- **Server — dispatch** (same harness): a thread addressed to a group with
  email-bearing members dispatches recipients covering those members; dedup with
  an overlapping direct contact; author excluded; a group the user can't address
  is skipped without failing the send.
- **Flutter — picker** (bloc test on `connectionsForRoster`): with a group
  selected, `addresses`-type connectors appear and the returned target carries
  `groups`; `contacts`-type DM connectors do not appear; `groups.isEmpty`
  behavior unchanged.
- **Flutter — member picker**: emailless contacts are disabled/hidden in the
  group create/edit member selector.

## Risk / compatibility

- No schema migration; `contact.email` stays nullable (the rule lives in the
  mutation functions, not the column). No API contract change.
- Server expansion is additive: threads without groups behave exactly as before.
- The connector receives a normal expanded `draft.contacts`; no SDK or connector
  change is required.
- The membership rule is enforced only on user-facing mutations, so
  trigger-driven auto-maintained groups are unaffected.
