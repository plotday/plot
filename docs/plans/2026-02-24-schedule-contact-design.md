# Schedule Contact Design

Migrate event invitee and RSVP tracking from thread tags to a dedicated `schedule_contact` table.

## Motivation

The tag-based RSVP system (Attend/Skip/Undecided as count tags on `thread_tag`) is incompatible with the current architecture:

- RSVPs need to be per-event or per-event-exception, but tags are on threads and notes
- Schedule is now separate from threads, with multiple schedules possible per thread
- Schedule exceptions (occurrences) need their own RSVP tracking
- The tag system can't model this correctly

## Data Model

### schedule_contact table

```sql
CREATE TABLE "public"."schedule_contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "schedule_id" uuid NOT NULL REFERENCES public.schedule(id) ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES public.contact(id) ON DELETE CASCADE,
    "status" text CHECK (status IN ('attend', 'skip')),
    "role" text CHECK (role IN ('organizer', 'required', 'optional')),
    CONSTRAINT schedule_contact_unique UNIQUE (schedule_id, contact_id)
);
```

### Row lifecycle

- Row exists = invited
- `archived_at` set = invitation removed
- `status` null = undecided (invited, no response)
- `status = 'attend'` = attending
- `status = 'skip'` = not attending

### Role values

Captured from external calendar APIs:
- `organizer` = event organizer
- `required` = required attendee
- `optional` = optional attendee
- `null` = role not specified

### Recurring events

Handled by the existing schedule occurrence model. Recurring schedules produce occurrence exception rows in the `schedule` table. Each schedule row (whether series or exception) has its own `schedule_contact` rows. No `occurrence` column needed on `schedule_contact`.

### Contact reference

Uses `contact_id` only (no `user_id`). Consistent with the rest of the system where even users are referenced via their contact record.

## SDK Types

In `public/twister/src/schedule.ts`:

```typescript
export type ScheduleContactStatus = 'attend' | 'skip';
export type ScheduleContactRole = 'organizer' | 'required' | 'optional';

export type ScheduleContact = {
  contact: ActorId;
  status: ScheduleContactStatus | null;
  role: ScheduleContactRole | null;
  archived: boolean;
};

export type NewScheduleContact = {
  contact: NewActor;
  status?: ScheduleContactStatus | null;
  role?: ScheduleContactRole | null;
  archived?: boolean;
};
```

### Extended types

- `Schedule` gets `contacts: ScheduleContact[]`
- `NewSchedule` gets `contacts?: NewScheduleContact[]`
- `NewScheduleOccurrence` gets `contacts?: NewScheduleContact[]`

### Upsert semantics

Contacts in the array are upserted by contact identity (email/id). Contacts not mentioned are left unchanged. To remove a contact, set `archived: true`.

This handles both patterns:
- Sources provide all attendees on every sync (effectively full replacement)
- User RSVPs in Plot update just one contact's status

## RSVP Tag Removal

### SDK

Remove from `Tag` enum in `public/twister/src/tag.ts`:
- `Attend = 1019`
- `Skip = 1020`
- `Undecided = 1021`

### Database

- Remove `is_rsvp_tag()` function
- Remove mutual exclusivity logic in `update_thread_tags`
- Data migration: archive existing RSVP `thread_tag` rows

### Flutter

- Remove `isRsvp` getter and `rsvpTags` list from tag store
- Remove RSVP-specific handling in thread_tags

## Sync

Schedule contacts sync as nested data on the schedule sync, not as a separate endpoint:

- Schedule sync view/endpoint includes `contacts` as a joined array
- Changes to `schedule_contact` bump `schedule.updated_at`
- `notify_internal_api_for_schedule()` includes contact data
- Flutter local store gets a `schedule_contact` Drift table

### User RSVP flow

1. User changes RSVP in Flutter app
2. Flutter writes to local `schedule_contact` table
3. Syncs to server via schedule update
4. Server writes to DB, triggers notification
5. Source picks up change and writes back to external calendar

## Source Updates

Google Calendar and Outlook Calendar sources:

- Map attendees to `contacts` on `NewSchedule` / `NewScheduleOccurrence` instead of RSVP tags
- Map external status values:
  - Google: accepted -> attend, declined -> skip, tentative/needsAction -> null (undecided)
  - Outlook: accepted -> attend, declined -> skip, tentativelyAccepted/none/notResponded -> null
- Map external roles:
  - Google: organizer flag -> organizer, optional flag -> optional, else required
  - Outlook: type field maps directly to organizer/required/optional
- RSVP write-back reads from schedule_contact changes instead of tag changes
