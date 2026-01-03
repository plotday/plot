CREATE TYPE "public"."activity_type" AS enum (
    'action', -- doesn't block time; incomplete until done_at is set
    'event', -- blocks time
    'note'
);

CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    -- Actor ID (contact ID or priority_twist_id) to credit with creating this activity
    "author_id" uuid NOT NULL,
    -- User ID (not contact ID) or priority_twist_id that created this activity
    "created_by" uuid NOT NULL DEFAULT auth.uid (),
    "assignee_id" uuid, -- author
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "type" activity_type NOT NULL DEFAULT 'note' ::activity_type,
    "order" double precision NOT NULL DEFAULT public.order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "preview" text,
    -- Scheduling fields
    -- at/on span the range the activity is scheduled for, including recurrences.
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "recurrence_rule" text,
    "recurrence_exdates" timestamptz[],
    "recurrence_dates" timestamptz[],
    "meta" jsonb,
    "source" text,
    "created_by_twist_id" bigint,
    "embedding" halfvec (384),
    "pick_priority" jsonb,
    "last_note_created_at" timestamp with time zone,
    "active_source" text GENERATED ALWAYS AS ( CASE WHEN archived_at IS NULL THEN
        source
    ELSE
        NULL
    END) STORED
);

CREATE INDEX ON activity USING hnsw (embedding halfvec_cosine_ops);

CREATE TABLE "public"."activity_exception" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL REFERENCES public.activity (id),
    "occurrence" text NOT NULL,
    -- overrides the root activity's fields
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "title" text,
    "note" text,
    "meta" jsonb
);

COMMENT ON COLUMN "public"."activity"."author_id" IS 'The actor to credit with creating this activity. For activities created by twists on behalf of contacts or users, this is the contact/user. For activities created directly by users or twists, this is the user/twist ID.';

COMMENT ON COLUMN "public"."activity"."created_by" IS 'The user_id or priority_twist_id that actually created this activity. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."activity"."source" IS 'External source identifier for deduplication and sync. Provided as a top-level field in the Activity type (not stored in meta). Indexed for efficient lookups. Used with created_by_twist_id for upsert behavior.';

COMMENT ON COLUMN "public"."activity"."created_by_twist_id" IS 'The twist definition ID (twist_admin.id) that created this activity. Null for user-created activities. Used with source for per-twist deduplication.';

COMMENT ON COLUMN "public"."activity"."pick_priority" IS 'The PickPriorityConfig used to automatically select this activity''s priority. Null if priority was explicitly specified. Used when moving activities to find similar activities to move. Not exposed to app or API.';

COMMENT ON COLUMN "public"."activity"."last_note_created_at" IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for range_at computation and unread status in user_activity view.';

COMMENT ON COLUMN "public"."activity_exception"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_single_schedule CHECK (at IS NULL OR "on" IS NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_recurrence_on_or_at CHECK (recurrence_rule IS NULL OR at IS NOT NULL OR "on" IS NOT NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_scheduled CHECK ((recurrence_rule IS NULL AND TYPE NOT IN ('action', 'event')) OR at IS NOT NULL OR "on" IS NOT NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_no_complete_recurrence CHECK (recurrence_rule IS NULL OR "done_at" IS NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_action_assignee CHECK (TYPE != 'action' OR assignee_id IS NOT NULL);

CREATE INDEX idx_activity_priority_id ON "public"."activity" ("priority_id");

CREATE INDEX idx_activity_at ON "public"."activity" USING gist ("at");

CREATE INDEX idx_activity_on ON "public"."activity" USING gist ("on");

CREATE INDEX idx_activity_occurrence ON "public"."activity_exception" ("activity_id", "occurrence");

CREATE INDEX idx_activity_done_at ON "public"."activity" ("done_at");

-- Support common archived_at IS NULL filter in many views
CREATE INDEX idx_activity_archived ON "public"."activity" ("archived_at")
WHERE
    archived_at IS NULL;

-- Speed up joins from priority to non-archived activities
CREATE INDEX idx_activity_priority_archived ON "public"."activity" ("priority_id", "archived_at");

-- Index for efficient source lookups
CREATE INDEX idx_activity_source ON "public"."activity" ("source")
WHERE
    source IS NOT NULL;

-- Ensure one activity per source per twist
CREATE UNIQUE INDEX activity_source_twist_unique ON "public"."activity" ("active_source", "created_by_twist_id");

-- Index for created_at sorting (critical for pagination queries)
-- Includes priority_id to support common WHERE clauses
-- Only indexes non-archived activities (most common case)
CREATE INDEX idx_activity_created_at_priority ON "public"."activity" ("created_at" DESC, "priority_id")
WHERE
    archived_at IS NULL;

-- Optimized for user_activity_unread and user_priority_unread views
-- Supports efficient filtering and aggregation on last_note_created_at
CREATE INDEX idx_activity_priority_archived_last_note ON "public"."activity" ("priority_id", "last_note_created_at", "created_at")
WHERE
    archived_at IS NULL;

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity_exception" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_updated_at
    BEFORE INSERT OR UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_created_at
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_activity_exception_updated_at
    BEFORE INSERT OR UPDATE ON "public"."activity_exception"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_exception_created_at
    BEFORE INSERT ON "public"."activity_exception"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE OR REPLACE FUNCTION public.update_author_and_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Don't allow users to impersonate others
    NEW.author_id = COALESCE(user_contact_id (), NEW.author_id);
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER set_activity_author_and_created_by
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

CREATE TRIGGER activity_change_api_call
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_internal_api_for_activity ();

