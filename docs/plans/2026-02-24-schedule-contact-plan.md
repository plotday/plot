# Schedule Contact Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate event invitee and RSVP tracking from thread tags to a dedicated `schedule_contact` table linked to schedules.

**Architecture:** New `schedule_contact` join table (schedule_id, contact_id, status, role) with upsert semantics. Contacts are nested inline on `Schedule`/`NewSchedule` types in the SDK. RSVP tags (Attend/Skip/Undecided) are fully removed. Schedule sync view includes contacts as a joined array; changes to `schedule_contact` bump `schedule.updated_at` so existing sync picks them up.

**Tech Stack:** PostgreSQL schema + migrations (Atlas), TypeScript SDK types (Twister), Cloudflare Worker API (Hono/Kysely), Flutter local store (Drift/SQLite), calendar sources (Google Calendar, Outlook Calendar)

**Design doc:** `docs/plans/2026-02-24-schedule-contact-design.md`

---

### Task 1: Create schedule_contact database table

**Files:**
- Create: `libs/db/schema/50-tables/29-schedule_contact.sql`

**Step 1: Create the schema file**

```sql
CREATE TABLE "public"."schedule_contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "schedule_id" uuid NOT NULL REFERENCES public.schedule (id) ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES public.contact (id) ON DELETE CASCADE,
    "status" text CHECK (status IN ('attend', 'skip')),
    "role" text CHECK (role IN ('organizer', 'required', 'optional')),
    CONSTRAINT schedule_contact_unique UNIQUE (schedule_id, contact_id)
);

CREATE INDEX idx_schedule_contact_schedule_id ON "public"."schedule_contact" ("schedule_id");

CREATE INDEX idx_schedule_contact_contact_id ON "public"."schedule_contact" ("contact_id");

CREATE INDEX idx_schedule_contact_updated_at ON "public"."schedule_contact" ("updated_at");

CREATE TRIGGER set_schedule_contact_updated_at
    BEFORE INSERT OR UPDATE ON "public"."schedule_contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_schedule_contact_created_at
    BEFORE INSERT ON "public"."schedule_contact"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
```

**Step 2: Generate and apply migration**

```bash
pnpm gen-migration -- add_schedule_contact_table
pnpm apply-migrations
pnpm diff-schema-migrations  # Should show no differences
```

**Step 3: Commit**

```bash
git add libs/db/schema/50-tables/29-schedule_contact.sql libs/db/migrations/
git commit -m "Add schedule_contact table for per-schedule RSVP tracking"
```

---

### Task 2: Add trigger to bump schedule.updated_at on contact changes

When `schedule_contact` rows change, the parent `schedule.updated_at` must be bumped so the existing schedule sync picks up the changes.

**Files:**
- Create: `libs/db/schema/95-triggers/11-schedule-contact-bump.sql`

**Step 1: Create the trigger file**

```sql
-- When schedule_contact rows are inserted or updated, bump the parent schedule's updated_at
-- so that the schedule sync picks up the change.
CREATE OR REPLACE FUNCTION bump_schedule_updated_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    UPDATE schedule
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT schedule_id FROM new_table);
    RETURN NULL;
END;
$function$;

CREATE TRIGGER schedule_contact_bump_schedule_insert
    AFTER INSERT ON schedule_contact
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_schedule_updated_at ();

CREATE TRIGGER schedule_contact_bump_schedule_update
    AFTER UPDATE ON schedule_contact
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_schedule_updated_at ();
```

**Step 2: Generate and apply migration**

```bash
pnpm gen-migration -- add_schedule_contact_bump_trigger
pnpm apply-migrations
```

**Step 3: Commit**

```bash
git add libs/db/schema/95-triggers/11-schedule-contact-bump.sql libs/db/migrations/
git commit -m "Add trigger to bump schedule.updated_at on schedule_contact changes"
```

---

### Task 3: Add schedule_contact to the schedule sync view

The user-scoped schedule view (`libs/db/schema/90-user-schema/31-schedule.sql`) needs to include contacts as a JSON array so the Flutter app can sync them.

**Files:**
- Modify: `libs/db/schema/90-user-schema/31-schedule.sql`

**Step 1: Add contacts aggregation to the schedule view**

Add a `contacts` column that aggregates `schedule_contact` rows as a JSON array:

```sql
CREATE OR REPLACE VIEW "user"."schedule"
--
AS
SELECT
    upe.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    upe.path AS priority_path,
    -- range_at: for timestamp-based schedules
    CASE WHEN s.at IS NOT NULL THEN
        s.at
    ELSE
        NULL::tstzrange
    END AS range_at,
    -- range_on: for date-based schedules
    CASE WHEN s."on" IS NOT NULL THEN
        s."on"
    ELSE
        NULL::daterange
    END AS range_on,
    -- contacts: aggregated schedule_contact rows as JSON array
    COALESCE(
        (SELECT jsonb_agg(jsonb_build_object(
            'id', sc.id,
            'contact_id', sc.contact_id,
            'status', sc.status,
            'role', sc.role,
            'archived_at', sc.archived_at,
            'updated_at', sc.updated_at
        ) ORDER BY sc.created_at)
        FROM schedule_contact sc
        WHERE sc.schedule_id = s.id),
        '[]'::jsonb
    ) AS contacts
FROM
    schedule s
    JOIN thread a ON a.id = s.thread_id
    JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    -- Shared schedules visible to all priority members
    (s.user_id IS NULL
    -- Per-user schedules visible only to the owning user
    OR s.user_id = upe.user_id);

ALTER VIEW "user"."schedule" OWNER TO postgres;
```

**Step 2: Generate and apply migration**

```bash
pnpm gen-migration -- add_contacts_to_schedule_view
pnpm apply-migrations
```

**Step 3: Regenerate types and commit**

```bash
pnpm types
git add libs/db/schema/90-user-schema/31-schedule.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "Add contacts to schedule sync view"
```

---

### Task 4: Add upsert_schedule_contacts database function

A function to upsert schedule contacts (used by the API when processing inline contacts on schedules).

**Files:**
- Create: `libs/db/schema/90-user-schema/82-upsert_schedule_contacts.sql`

**Step 1: Create the upsert function**

```sql
-- Upsert schedule contacts for a given schedule.
-- Each contact is upserted by (schedule_id, contact_id).
-- Contacts not in the array are left unchanged (not deleted).
-- Set archived_at to remove a contact.
CREATE OR REPLACE FUNCTION "user".upsert_schedule_contacts (
    user_id uuid,
    p_schedule_id uuid,
    p_contacts jsonb
)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_contact jsonb;
    v_contact_id uuid;
    v_status text;
    v_role text;
    v_archived boolean;
    v_priority_id uuid;
BEGIN
    -- Validate user has access to the schedule's thread's priority
    SELECT a.priority_id INTO v_priority_id
    FROM schedule s
    JOIN thread a ON a.id = s.thread_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Schedule not found';
    END IF;

    IF NOT "user".has_priority_access(user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        v_contact_id := (v_contact ->> 'contact_id')::uuid;
        v_status := v_contact ->> 'status';
        v_role := v_contact ->> 'role';
        v_archived := COALESCE((v_contact ->> 'archived')::boolean, false);

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role, archived_at)
        VALUES (
            p_schedule_id,
            v_contact_id,
            v_status,
            v_role,
            CASE WHEN v_archived THEN now() ELSE NULL END
        )
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET
            status = CASE
                WHEN v_contact ? 'status' THEN EXCLUDED.status
                ELSE schedule_contact.status
            END,
            role = CASE
                WHEN v_contact ? 'role' THEN EXCLUDED.role
                ELSE schedule_contact.role
            END,
            archived_at = CASE
                WHEN v_archived THEN COALESCE(schedule_contact.archived_at, now())
                ELSE NULL
            END;

        -- Ensure priority_contact exists for the contact
        INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id) DO NOTHING;
    END LOOP;
END;
$function$;
```

**Step 2: Generate and apply migration**

```bash
pnpm gen-migration -- add_upsert_schedule_contacts
pnpm apply-migrations
```

**Step 3: Commit**

```bash
git add libs/db/schema/90-user-schema/82-upsert_schedule_contacts.sql libs/db/migrations/
git commit -m "Add upsert_schedule_contacts database function"
```

---

### Task 5: Add SDK types for schedule contacts

**Files:**
- Modify: `public/twister/src/schedule.ts`

**Step 1: Add ScheduleContact types**

At the top of `public/twister/src/schedule.ts`, add the imports needed, then add the new types after the existing `Schedule` type definition (after line 47):

```typescript
import { type ActorId, type NewActor } from "./plot";

export type ScheduleContactStatus = "attend" | "skip";
export type ScheduleContactRole = "organizer" | "required" | "optional";

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

**Step 2: Add `contacts` field to `Schedule` type**

In the `Schedule` type (line 17), add after `occurrence`:

```typescript
  /** Contacts invited to this schedule (attendees/participants) */
  contacts: ScheduleContact[];
```

**Step 3: Add `contacts` field to `NewSchedule` type**

In the `NewSchedule` type (line 80), add after `archived`:

```typescript
  /** Contacts to upsert on this schedule. Upserted by contact identity. */
  contacts?: NewScheduleContact[];
```

**Step 4: Add `contacts` field to `NewScheduleOccurrence` type**

In the `NewScheduleOccurrence` type (around line 149), add a `contacts` field:

```typescript
  /** Contacts to upsert on this occurrence's schedule */
  contacts?: NewScheduleContact[];
```

**Step 5: Rebuild Twister**

```bash
cd public/twister && pnpm build && cd ../..
pnpm install
```

**Step 6: Commit**

```bash
cd public && git add twister/src/schedule.ts && git commit -m "Add ScheduleContact types to SDK"
cd ..
git add public
git commit -m "Update public submodule: add ScheduleContact types"
```

---

### Task 6: Remove RSVP tags from SDK

**Files:**
- Modify: `public/twister/src/tag.ts`

**Step 1: Remove RSVP tag entries from Tag enum**

In `public/twister/src/tag.ts`, remove these lines (47-51):

```typescript
  // RSVP tags - mutually exclusive per actor
  // When an actor adds one of these tags, the other two are automatically removed
  Attend = 1019,
  Skip = 1020,
  Undecided = 1021,
```

**Step 2: Rebuild Twister**

```bash
cd public/twister && pnpm build && cd ../..
```

**Step 3: Commit**

```bash
cd public && git add twister/src/tag.ts && git commit -m "Remove RSVP tags (Attend/Skip/Undecided) from Tag enum"
cd ..
git add public
git commit -m "Update public submodule: remove RSVP tags"
```

---

### Task 7: Remove RSVP database logic

**Files:**
- Modify: `libs/db/schema/40-functions/30-tag.sql` — remove `is_rsvp_tag()` function
- Modify: `libs/db/schema/90-user-schema/10-update_thread_tags.sql` — remove RSVP exclusivity block

**Step 1: Remove `is_rsvp_tag()` function**

In `libs/db/schema/40-functions/30-tag.sql`, delete lines 22-33 (the entire `is_rsvp_tag` function and its comment):

```sql
-- Function to check if a tag_id is an RSVP tag (Attend/Skip/Undecided)
-- RSVP tags are mutually exclusive - an actor can only have one at a time
CREATE OR REPLACE FUNCTION is_rsvp_tag (tag_id integer)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    -- RSVP tags: Attend (1019), Skip (1020), Undecided (1021)
    RETURN tag_id IN (1019, 1020, 1021);
END;
$$;
```

**Step 2: Remove RSVP mutual exclusivity logic**

In `libs/db/schema/90-user-schema/10-update_thread_tags.sql`, remove lines 57-72 (the `IF is_rsvp_tag(tag_id_int)` block):

```sql
                -- RSVP tags (Attend/Skip/Undecided) are mutually exclusive
                -- If adding an RSVP tag, remove the other two for this actor
                IF is_rsvp_tag (tag_id_int) THEN
                    UPDATE
                        thread_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        thread_id = p_thread_id
                        AND actor_id = p_actor_id
                        AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                        AND tag_id IN (1019, 1020, 1021) -- All RSVP tags
                        AND tag_id != tag_id_int -- Except the one being added
                        AND archived_at IS NULL;
                END IF;
```

**Step 3: Generate migration with data migration**

```bash
pnpm gen-migration -- remove_rsvp_tag_logic
```

Then edit the generated migration to add a data migration that archives existing RSVP tags:

```sql
-- Archive existing RSVP thread_tag rows (Attend=1019, Skip=1020, Undecided=1021)
UPDATE thread_tag
SET archived_at = COALESCE(archived_at, now())
WHERE tag_id IN (1019, 1020, 1021)
AND archived_at IS NULL;
```

**Step 4: Apply and verify**

```bash
pnpm apply-migrations
pnpm diff-schema-migrations
```

**Step 5: Commit**

```bash
git add libs/db/schema/40-functions/30-tag.sql libs/db/schema/90-user-schema/10-update_thread_tags.sql libs/db/migrations/
git commit -m "Remove RSVP tag logic and archive existing RSVP tags"
```

---

### Task 8: Handle contacts in API schedule processing

When `saveThread` is called with `NewThread.schedules[].contacts` or `NewThread.scheduleOccurrences[].contacts`, the API needs to process those contacts (resolve NewActor to contact_id, then call `upsert_schedule_contacts`).

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread.ts` — add contact processing after schedule creation
- Modify: `workers/api/src/twist/tools/plot/index.ts` — add `processScheduleContacts` method or use existing infrastructure

**Step 1: Find where schedules are created in the thread flow**

Check `createThread` and `updateThread` functions in `workers/api/src/twist/tools/plot/thread.ts`. Currently `schedules` and `scheduleOccurrences` from `NewThread` are not yet processed inline. The schedule_contact processing should be added alongside schedule processing when that code exists.

If schedules are created separately (via sync endpoint), add contact processing to the `POST /sync/schedules` endpoint in `workers/api/src/app/sync/schedules.ts`.

**Step 2: Add a helper to process schedule contacts**

Create a helper that:
1. Takes a `scheduleId` and `NewScheduleContact[]`
2. Resolves each `NewActor` to a `contact_id` (using existing `addContacts` / `processNewActorArray` pattern)
3. Calls `upsert_schedule_contacts` RPC

This can go in a new file `workers/api/src/twist/tools/plot/schedule-contacts.ts` or inline where needed.

```typescript
import type { NewScheduleContact } from "@plotday/twister/schedule";
import type { Plot } from "./index";
import { addContacts } from "./contacts";
import { rpcUser } from "../../../rpc";

export async function processScheduleContacts(
  plot: Plot,
  scheduleId: string,
  contacts: NewScheduleContact[]
): Promise<void> {
  // Resolve NewActor (email/name) to contact_id via addContacts
  const resolvedContacts = await Promise.all(
    contacts.map(async (sc) => {
      let contactId: string;
      if ("id" in sc.contact) {
        contactId = sc.contact.id;
      } else {
        // Create or find contact by email
        const [actor] = await addContacts(plot, [sc.contact]);
        contactId = actor.id;
      }
      return {
        contact_id: contactId,
        status: sc.status ?? null,
        role: sc.role ?? null,
        archived: sc.archived ?? false,
      };
    })
  );

  const userId = await plot.getUserId();
  await rpcUser(plot.db, "upsert_schedule_contacts", {
    user_id: userId,
    p_schedule_id: scheduleId,
    p_contacts: resolvedContacts,
  });
}
```

**Step 3: Wire into the schedule creation/upsert flow**

Wherever schedules are created (either inline from `NewThread.schedules` or via the sync endpoint), call `processScheduleContacts` after the schedule is created if `contacts` are provided.

**Step 4: Verify API builds**

```bash
pnpm --filter @plotday/api build
```

**Step 5: Commit**

```bash
git add workers/api/src/twist/tools/plot/schedule-contacts.ts workers/api/src/
git commit -m "Add schedule contact processing to API"
```

---

### Task 9: Update Google Calendar source

**Files:**
- Modify: `public/sources/google-calendar/src/google-calendar.ts`
- Modify: `public/sources/google-calendar/src/google-api.ts` (if attendee-to-contact mapping is here)

**Step 1: Replace RSVP tag mapping with contacts**

In the event processing code (~lines 700-755), replace the `Tag.Attend`/`Tag.Skip`/`Tag.Undecided` tag arrays with `NewScheduleContact[]`:

Map Google responseStatus values:
- `"accepted"` → `status: "attend"`
- `"declined"` → `status: "skip"`
- `"tentative"` / `"needsAction"` → `status: null` (undecided)

Map Google attendee fields to roles:
- `attendee.organizer === true` → `role: "organizer"`
- `attendee.optional === true` → `role: "optional"`
- Otherwise → `role: "required"`

**Step 2: Set contacts on NewSchedule instead of tags**

For non-recurring events, set `contacts` on the schedule in `NewThread.schedules[]`.
For recurring event occurrences, set `contacts` on `NewScheduleOccurrence`.

**Step 3: Update RSVP write-back**

In `onThreadUpdated()` (~lines 1100-1175), update the write-back logic to read RSVP from schedule contacts instead of tag changes. This will need to detect changes to `schedule_contact` status for the acting user and push to Google Calendar API.

**Step 4: Build and test**

```bash
cd public/sources/google-calendar && pnpm build && cd ../../..
```

**Step 5: Commit**

```bash
cd public && git add sources/google-calendar/ && git commit -m "Use schedule contacts instead of RSVP tags for Google Calendar"
cd ..
git add public
git commit -m "Update public submodule: Google Calendar uses schedule contacts"
```

---

### Task 10: Update Outlook Calendar source

**Files:**
- Modify: `public/sources/outlook-calendar/src/outlook-calendar.ts`
- Modify: `public/sources/outlook-calendar/src/graph-api.ts` (if attendee mapping is here)

**Step 1: Replace RSVP tag mapping with contacts**

Map Microsoft Graph attendee status values:
- `"accepted"` → `status: "attend"`
- `"declined"` → `status: "skip"`
- `"tentativelyAccepted"` / `"none"` / `"notResponded"` → `status: null`
- `"organizer"` → `status: null, role: "organizer"`

Map attendee type to roles:
- `type: "required"` → `role: "required"`
- `type: "optional"` → `role: "optional"`
- `type: "resource"` → filter out (same as current behavior)

**Step 2: Set contacts on schedules, update write-back**

Same approach as Google Calendar (Task 9 steps 2-3).

**Step 3: Build and test**

```bash
cd public/sources/outlook-calendar && pnpm build && cd ../../..
```

**Step 4: Commit**

```bash
cd public && git add sources/outlook-calendar/ && git commit -m "Use schedule contacts instead of RSVP tags for Outlook Calendar"
cd ..
git add public
git commit -m "Update public submodule: Outlook Calendar uses schedule contacts"
```

---

### Task 11: Remove RSVP from Flutter

**Files:**
- Modify: `apps/plot/lib/store/tag.dart` — remove RSVP tag definitions and helpers
- Modify: `apps/plot/lib/store/thread.dart` — remove RSVP exclusivity logic
- Modify: `apps/plot/lib/store/note.dart` — remove RSVP exclusivity logic
- Modify: `apps/plot/lib/command/thread.dart` — remove RSVP tag commands

**Step 1: Remove RSVP tags from tag.dart**

In `apps/plot/lib/store/tag.dart`:
- Remove the `attend`, `skip`, `undecided` enum values (~lines 202-225)
- Remove `isRsvp` getter (line 256): `bool get isRsvp => this == Tag.attend || this == Tag.skip || this == Tag.undecided;`
- Remove `rsvpTags` static list (line 259): `static List<Tag> get rsvpTags => [Tag.attend, Tag.skip, Tag.undecided];`

**Step 2: Remove RSVP exclusivity from thread.dart**

In `apps/plot/lib/store/thread.dart` (~lines 2107-2125), remove the block that checks `tag.isRsvp` and removes other RSVP tags.

**Step 3: Remove RSVP exclusivity from note.dart**

In `apps/plot/lib/store/note.dart` (~lines 697-710), remove the RSVP mutual exclusivity block.

**Step 4: Remove RSVP commands from thread.dart**

In `apps/plot/lib/command/thread.dart`, remove RSVP-specific tag toggling commands (~lines 730, 749, 768) and any RSVP filtering logic (~lines 1169, 1259).

**Step 5: Verify Flutter compiles**

```bash
cd apps/plot && flutter analyze lib/store/tag.dart lib/store/thread.dart lib/store/note.dart lib/command/thread.dart
```

**Step 6: Commit**

```bash
git add apps/plot/lib/store/tag.dart apps/plot/lib/store/thread.dart apps/plot/lib/store/note.dart apps/plot/lib/command/thread.dart
git commit -m "Remove RSVP tag logic from Flutter app"
```

---

### Task 12: Add schedule_contact Drift table to Flutter

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` — add `ScheduleContacts` Drift table alongside `Schedules`
- Modify: `apps/plot/lib/store/store.dart` — register the new table

**Step 1: Add the ScheduleContacts Drift table**

In `apps/plot/lib/store/thread.dart`, after the `Schedules` table definition (~line 71), add:

```dart
@DataClassName('ScheduleContactRow')
class ScheduleContacts extends Table {
  IntColumn get id => integer()();
  BlobColumn get scheduleId => blob().map(const UuidConverter())();
  BlobColumn get contactId => blob().map(const UuidConverter())();
  TextColumn get status => text().nullable()();
  TextColumn get role => text().nullable()();
  DateTimeColumn get archivedAt => dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get updatedAt => dateTime().map(const LocalDateTimeConverter())();

  @override
  Set<Column> get primaryKey => {id};
}
```

**Step 2: Register the table in store.dart**

Add `ScheduleContacts` to the list of tables in the `@DriftDatabase` annotation in `apps/plot/lib/store/store.dart`.

**Step 3: Parse contacts from schedule sync response**

In the `SchedulesBase` class `fromBase()` method, parse the `contacts` JSON array from the sync response and insert/update `ScheduleContacts` rows.

**Step 4: Rebuild Drift generated code**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

**Step 5: Verify**

```bash
cd apps/plot && flutter analyze
```

**Step 6: Commit**

```bash
git add apps/plot/lib/store/
git commit -m "Add schedule_contact Drift table to Flutter local store"
```

---

### Task 13: Squash migrations and final verification

Before merging, squash development migrations into clean ones.

**Step 1: Squash migrations**

Follow the squashing process from `libs/db/CLAUDE.md`:
- Delete development migration files
- Recalculate Atlas hash
- Remove from Atlas tracking table
- Generate clean migrations
- Apply and test

**Step 2: Full verification**

```bash
# Database schema is in sync
pnpm diff-schema-migrations

# Types are generated
pnpm types

# API builds
pnpm --filter @plotday/api build

# Twister builds
cd public/twister && pnpm build && cd ../..

# Sources build
cd public/sources/google-calendar && pnpm build && cd ../../..
cd public/sources/outlook-calendar && pnpm build && cd ../../..

# Flutter analyzes cleanly
cd apps/plot && flutter analyze
```

**Step 3: Final commit**

```bash
git add -A
git commit -m "Squash schedule_contact migrations"
```
