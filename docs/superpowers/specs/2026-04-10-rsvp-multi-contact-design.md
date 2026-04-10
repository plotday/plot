# RSVP Multi-Contact Resolution

**Status:** Approved
**Date:** 2026-04-10
**Author:** Kris Braun
**Related:** Commit `919945043` (thread visibility for non-primary linked contacts)

## Problem

`update_schedule_contact_status` always writes the `schedule_contact` row keyed on the user's **primary** contact (`user.user_contact_id(user_id)`). When a user RSVPs to an event that came from a non-primary calendar — e.g. `kris@plot.day` (primary) RSVPing to a `kris.braun@gmail.com` event — three things break:

1. **Wrong row.** Sync wrote the original attendee row under the `kris.braun@gmail.com` contact. The RSVP creates a *second* row under the `kris@plot.day` contact. Two rows for one human, neither marking the actual attendee as attending.
2. **Wrong write-back.** The `onScheduleContactUpdated` callback fires for the contact whose row changed and calls `tools.integrations.actAs(Google, contact_id, ...)`. With the primary contact, the connector picks up the `kris@plot.day` Google auth token and tries to PATCH a calendar it doesn't own.
3. **Stale state on next sync.** The original `kris.braun@gmail.com` attendee row still has whatever status came from Google, so the user's choice is shadowed by stale data on subsequent reconciles.

## Goals

- A user can RSVP to any schedule on a thread they have access to, regardless of which of their linked contacts was the original attendee.
- The RSVP updates the row that sync produced, so the connector write-back uses the correct account's auth token and the connector's existing email-matching logic finds the right attendee on the source side.
- Native (non-synced) schedules where the user has no pre-existing row continue to work; their RSVP creates a row under their primary contact.
- No regression for users with only a primary contact, and no regression for events whose attendee row already happens to be the primary contact.

## Non-Goals

- Migrating historical orphan rows that prior primary-contact RSVPs created. They remain harmless on the data layer (they don't represent any real attendee from Google's perspective) and will be reconciled implicitly on next sync. A cleanup migration may follow if needed but is not part of this spec.
- Changing `update_thread_tags`, `upsert_thread_tag`, or `upsert_note_tag`. The previous fix (commit `919945043`) made count-tag ownership accept any linked contact, which is sufficient for any current and future count-tag usage.
- Changing the Flutter client. The endpoint signature is unchanged; only server semantics shift.
- Changing the connector RSVP write-back code. The improved actor selection means the existing `actAs` path receives a useful contact_id; nothing else is required.

## Background: where RSVPs actually live

I traced both the sync side and the user-action side to confirm the storage model before designing.

- **Sync.** The Google Calendar connector calls `saveLink` with `NewScheduleContact[]`. Server-side, `upsert_schedule_contacts` creates one `schedule_contact` row per attendee, keyed on `(schedule_id, contact_id)`. No tag rows are written.
- **User RSVP.** Flutter's `command/thread.dart:524` posts to `/sync/schedule/status`. The handler in `workers/api/src/app/sync/schedules.ts:199` calls `update_schedule_contact_status`. Again, no tag writes.
- **UI rendering.** `apps/plot/lib/store/thread.dart:2516` derives `currentUserRsvp` from `schedule_contact` rows. `apps/plot/lib/store/thread.dart:2520` (`isDeclinedByUser`) iterates `scheduleContacts` and aggregates by user. Nothing reads count tags for RSVP.
- **Connector write-back.** `onScheduleContactUpdated` fires per row change → `actAs(provider, contact.id, ...)` → connector uses the contact's auth token. `updateEventRSVPWithApi` matches the attendee on the source side by `auth.calendarList.id` (the token's primary calendar email), so once the right token is selected, the right attendee gets PATCHed.

`schedule_contact` is the sole source of truth for RSVP. The "RSVP Tags" entry that previously appeared in `AGENTS.md` was stale documentation; this spec also corrects it.

## Design

### Function: `user.update_schedule_contact_status`

Signature is unchanged: `(user_id uuid, p_schedule_id uuid, p_status text) RETURNS void`.

New behavior:

1. Validate that the schedule exists and resolve its priority via the existing `s.thread_id`/`s.link_id` join. Raise `Schedule not found` if neither path resolves.
2. Validate that the user has priority access via `user.has_priority_access`. Raise `User does not have access to this schedule` otherwise.
3. Validate `p_status IN ('attend', 'skip', NULL)`. Raise `Invalid status` otherwise.
4. **Resolve actor candidates.** Use `user.user_contact_ids(user_id)` (added in commit `919945043`) — returns every non-archived `contact_id` linked to the user, including the primary.
5. **Update existing rows.** `UPDATE schedule_contact SET status = p_status WHERE schedule_id = p_schedule_id AND contact_id = ANY(<candidates>) AND archived_at IS NULL`. If multiple of the user's linked contacts are independent attendees on the same schedule, all rows get the same status — they all represent the same human, so they should agree.
6. **Fall back to insert** only if step 5 affected zero rows. The insert keys on `user.user_contact_id(user_id)` (primary) with `role = 'required'` and `status = p_status`.
7. **Error on no contact.** If step 5 affected zero rows and the primary lookup is `NULL`, raise the existing `User has no contact record` error.

### SQL sketch

```sql
CREATE OR REPLACE FUNCTION "user".update_schedule_contact_status (
    user_id uuid,
    p_schedule_id uuid,
    p_status text
)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_priority_id uuid;
    v_primary_contact_id uuid;
    v_updated_count integer;
BEGIN
    -- Existing validation (unchanged)
    SELECT
        CASE
            WHEN s.thread_id IS NOT NULL THEN t.priority_id
            WHEN s.link_id IS NOT NULL THEN lt.priority_id
        END INTO v_priority_id
    FROM schedule s
    LEFT JOIN thread t ON t.id = s.thread_id
    LEFT JOIN link l ON l.id = s.link_id
    LEFT JOIN thread lt ON lt.id = l.thread_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Schedule not found';
    END IF;

    IF NOT "user".has_priority_access(user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    IF p_status IS NOT NULL AND p_status NOT IN ('attend', 'skip') THEN
        RAISE EXCEPTION 'Invalid status: must be attend, skip, or null';
    END IF;

    -- Try to update any existing rows that already represent this user
    UPDATE schedule_contact
    SET status = p_status
    WHERE schedule_id = p_schedule_id
      AND contact_id = ANY("user".user_contact_ids(user_id))
      AND archived_at IS NULL;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    -- Fall back to inserting a new row for the primary contact
    IF v_updated_count = 0 THEN
        v_primary_contact_id := "user".user_contact_id(user_id);
        IF v_primary_contact_id IS NULL THEN
            RAISE EXCEPTION 'User has no contact record';
        END IF;

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role)
        VALUES (p_schedule_id, v_primary_contact_id, p_status, 'required')
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET status = EXCLUDED.status;
    END IF;
END;
$function$;
```

The `ON CONFLICT` on the insert handles the race where another concurrent RSVP races us to create the primary-contact row. It also handles the (rare) case where an archived row exists for the primary contact: we update it instead of erroring on the unique constraint. We deliberately do NOT clear `archived_at` in the insert path — if the row was archived, that was a deliberate cleanup and the `status` update alone is enough.

### Why match-then-fall-back, not other approaches considered

**Alternative B: Resolve by source provider metadata.** Read the schedule's link → meta → `syncProvider`/`channelId` and pick the user's contact whose email matches the channel.
Rejected because (a) it requires plumbing through link metadata, (b) it falls apart if the schedule didn't come from sync, and (c) in the common case it reduces to the recommended approach anyway — the existing `schedule_contact` row already encodes "this account knew about this event."

**Alternative C: Always write to all linked contacts.** Insert/update one row per linked contact unconditionally.
Rejected because it creates `schedule_contact` rows for contacts who have nothing to do with the event, polluting attendee lists and confusing connector write-back paths that iterate attendees.

## Edge cases

| Case | Behavior |
|---|---|
| Single primary contact, schedule has primary row | UPDATE that row (parity with current behavior) |
| Primary + non-primary, schedule has only non-primary row | UPDATE non-primary row (the fix) |
| Primary + non-primary, schedule has both rows | UPDATE both for consistency |
| Primary + non-primary, schedule has neither | INSERT under primary, `role='required'` |
| Native Plot schedule, no synced attendees | INSERT under primary, `role='required'` |
| User has only an archived primary contact | Existing `User has no contact record` error (unchanged; rare; out of scope) |
| `p_status = NULL` (clearing RSVP) | UPDATE matching rows to NULL, or INSERT under primary with NULL status |
| Concurrent RSVPs racing to create the primary row | ON CONFLICT handles cleanly |
| Archived primary row, no other rows | INSERT path's ON CONFLICT updates the archived row's status without unarchiving |

## Count-tag system: explicit non-interaction

This section is in the spec because the previous design review surfaced an apparent conflict between RSVP storage and count tags.

There is no conflict. RSVPs do not write count tags today, and this design does not start writing them. The count-tag system handles non-RSVP count tags (whatever those may be in the future); RSVP handles RSVP. The previous commit's fix to count-tag ownership (accepting any of the user's linked contacts as `p_actor_id`) is sufficient for count tags to work correctly with multi-contact users for any future use.

If RSVPs ever begin writing count tags too — e.g. to back an "RSVP chip" UI on threads that lack a schedule, or for offline-first ordering — the contract is:

- The RSVP-tag write path MUST resolve `p_actor_id` the same way `update_schedule_contact_status` does: prefer a contact already attached to the schedule's `schedule_contact` rows, fall back to primary.
- The simplest extension would be a helper `user.resolve_rsvp_actor(user_id, schedule_id) RETURNS uuid` reused by both paths. We do not extract this helper now (YAGNI); the SQL inside `update_schedule_contact_status` factors cleanly enough that extracting it later is mechanical.

`AGENTS.md` is updated in this same change to:
- Remove the "RSVP Tags" definition (which was stale)
- Add an "RSVP" definition that documents the actual storage model
- Update the "Count Tag Ownership" definition to reflect the multi-contact ownership rule and the correct database function names

## Testing

pgTAP tests in `libs/db/tests/`:

1. **Single primary, schedule has primary row**: existing row's `status` updates from `null` → `'attend'`. No new rows.
2. **Multi-contact user, schedule has only non-primary row**: that row updates; no new row created; primary contact has zero `schedule_contact` rows on this schedule.
3. **Multi-contact user, schedule has both primary and non-primary rows**: both rows update to the same status.
4. **Native schedule, no existing rows for any user contact**: a new row is inserted under primary with `status` set, `role = 'required'`, `archived_at IS NULL`.
5. **Concurrent insert race**: two transactions calling `update_schedule_contact_status` in the fall-back path; both succeed; exactly one row exists for the primary contact afterward, with the second caller's status winning (since UPDATE-on-conflict overwrites).
6. **User has no non-archived contacts at all**: function raises `User has no contact record`.
7. **`p_status = NULL` against existing row**: status clears to NULL.
8. **Schedule not found / no priority access / invalid status**: existing error paths still raise.

The fixtures need:
- Two users — one with a primary-only contact, one with primary + non-primary contacts
- A priority both users can access
- A thread with a base schedule
- Pre-seeded `schedule_contact` rows in different combinations per test

## Migration

A single Atlas-generated migration that replaces the function body. No data migration. The function is `CREATE OR REPLACE FUNCTION` so the change is fully online. No constraint changes, no row updates, no downtime risk.

## Out-of-scope follow-ups

- **Cleanup of historical orphan primary-contact RSVP rows.** A targeted UPDATE to migrate them onto the matching non-primary contact (where one exists) and delete the orphan. Likely a separate one-shot data migration; not urgent because next sync will reconcile and the orphans are harmless.
- **`update_schedule_contact_status` for archived primary contacts.** Today the function (and `user_contact_id`) doesn't filter primary by `archived_at`. If we ever support archiving the primary contact while keeping the user account active, both call sites need a fall-back to the next non-archived linked contact. Not addressing now; rare and orthogonal.
- **`update_thread_tags` priority_contact entries.** Today the function inserts a `priority_contact` row when `p_actor_id` references a contact. With multi-contact ownership, this could create more rows than before; behavior is correct (each linked contact gets a `priority_contact` entry as it's first used) but worth noting in case there's a contact-cap concern.
