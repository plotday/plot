# Inviteable Contacts

## Goal

Hide non-human / notification-only addresses (e.g. `no-reply@github.com`, `mailer-daemon@…`) from contact pickers throughout the app, so users aren't offered them as people to share threads with, assign to, or @mention.

The filter must be controllable server-side without an app update, and the design must allow future signals (e.g. "user has ever replied to this address") to feed into the same flag.

## Approach

Add a boolean `inviteable` column to `public.contact`. Default `true`; flip to `false` for junk. Compute via a shared TypeScript classifier invoked on every contact insert/update in the API, plus a one-shot SQL backfill in the migration. Pickers filter on `inviteable = true`; display paths (existing thread/note contact lookups by id) are unchanged.

## Schema

### `public.contact`

Add column:

```sql
ALTER TABLE contact ADD COLUMN inviteable boolean NOT NULL DEFAULT true;
```

### `public.actor` view (`libs/db/schema/70-views/30-actor.sql`)

Add `c.inviteable` to the contact branch. Twist-instance branch returns `true` (twists are not contact-picker candidates; the column is only consulted by pickers).

### `user.actor` view (`libs/db/schema/90-user-schema/34-actor.sql`)

Pass `inviteable` through from `actor` in all three UNION branches (primary contacts, non-primary contacts, twist instances).

### Flutter (`apps/plot/lib/store/actor.dart`)

Add to `Actors` table:

```dart
BoolColumn get inviteable => boolean().withDefault(const Constant(true))();
```

Bump `Store.schemaVersion`; add migration step using `addColumn`.

## Classifier

New file `workers/api/src/state/contact-classifier.ts`:

```typescript
export function classifyInviteable(
  email: string | null,
  name?: string | null,
): boolean;
```

- Returns `true` for null/empty email (can't classify; safer default).
- Lowercases and splits `email` into local and domain.
- Returns `false` when any of the following match:

**Local-part exact match:**
`no-reply`, `noreply`, `donotreply`, `do-not-reply`, `mailer-daemon`, `postmaster`, `bounces`, `bounce`, `notifications`, `notification`, `alerts`, `alert`, `auto-confirm`, `automated`.

**Local-part prefix:**
`noreply-`, `no-reply-`, `donotreply-`, `notification-`, `notifications-`, `reply+` (GitHub-style reply addresses).

**Local-part contains (with word boundary):**
`-noreply`, `-no-reply`, `-donotreply`.

**Domain match (subdomain-aware):**
- Any label equals `bounces`, `bounce`, or `mailer` (e.g. `em.bounces.foo.com`, `mailer.acme.com`).

Emits `tracker.capture('contact_classified_noninviteable', { email_hash, reason })` on every `false` return so we can audit coverage and tune patterns.

`name` is accepted in the signature for future use; not consulted initially.

## Wire-up

All 5 insert paths receive the computed `inviteable`:

- `workers/api/src/twist/tools/integrations.ts:2314`
- `workers/api/src/twist/tools/plot/contacts.ts:200`
- `workers/api/src/app/link-email.ts:415`
- `workers/api/src/app/account.ts:122`
- `workers/api/src/app/account.ts:578`

On update paths that change `email`, re-classify and write the new value. Paths that only update `name` / `avatar_url` leave `inviteable` alone.

## Migration

One migration generated via `pnpm gen-migration -- add_contact_inviteable`:

1. `ALTER TABLE contact ADD COLUMN inviteable …`
2. Rough backfill (SQL regex — intentionally less precise than the TS classifier; TS is the source of truth going forward):

   ```sql
   UPDATE contact SET inviteable = false
   WHERE email IS NOT NULL
     AND (
       email ~* '^(no-?reply|do-?not-?reply|mailer-daemon|postmaster|bounces?|notifications?|alerts?|auto-confirm|automated)(-|\+|@)'
       OR email ~* '@([^@]*\.)?(bounces?|mailer)\.'
       OR split_part(email, '@', 1) ~* '(^|-)(noreply|no-reply|donotreply)(-|$)'
     );
   ```

3. Updates to `public.actor` and `user.actor` views.

Rows missed by the regex will only be reclassified on a subsequent insert/update that changes `email`. To catch edge patterns added later, ship a follow-up migration that re-runs the (improved) backfill.

## App filtering

Add `inviteable` to the `Actor` class. Filter to `inviteable == true` in:

- `Actor.getSortedForSharing` (`lib/store/actor.dart:176`) — filter candidates before sort.
- `ActorGroup.list` (`lib/command/thread.dart:1031`).
- `_ThreadShareContactsGroup.list` (`lib/command/thread.dart:1972`).
- Assignee picker (`lib/page/thread.dart:844`).
- `@mention` watcher in `PriorityBloc` (`lib/state/priority.dart:1162`).

Display paths (thread contact chips, note author avatars/names, thread.contacts lookups) do NOT filter. A thread created from a no-reply email still shows the sender's name where it already does today.

## Out of scope

- Per-user overrides. The global flag is sufficient for the patterns we're targeting; if user A sees a contact that user B considers junk, that's a future problem.
- UI to manually mark a contact as junk / inviteable.
- Sent-to or reply-history signals. The classifier is designed to incorporate these later without schema change.
- Twist instance filtering. Twists are already excluded from the affected pickers by `types: [user, contact]`.

## Testing

- Unit tests for `classifyInviteable` covering each pattern category plus counter-examples (`support@`, `hello@`, `kris@plot.day` must remain `true`).
- Integration: new contact created via `link-email` path with a `no-reply@` sender lands with `inviteable = false`.
- Manual: existing no-reply contacts disappear from share/assignee/@mention pickers after migration; still render by name in thread views.
