CREATE TYPE "public"."activity_type" AS enum (
    'task', -- doesn't block time; incomplete until done_at is set
    'event', -- blocks time
    'note'
);

CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL,
    "assignee_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "type" activity_type NOT NULL DEFAULT 'note' ::activity_type,
    "path" ltree NOT NULL DEFAULT generate_path (NULL),
    "order" double precision NOT NULL DEFAULT public.order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "note" text, -- markdown
    "links" jsonb,
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
    "mentions" uuid[],
    "embedding" halfvec (384),
    "pick_priority" jsonb
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

COMMENT ON COLUMN "public"."activity"."mentions" IS 'Array of actor IDs (user_id, contact_id, or priority_twist_id) that are mentioned in this activity via @-mentions.';

COMMENT ON COLUMN "public"."activity"."pick_priority" IS 'The PickPriorityConfig used to automatically select this activity''s priority. Null if priority was explicitly specified. Used when moving activities to find similar activities to move. Not exposed to app or API.';

COMMENT ON COLUMN "public"."activity_exception"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_single_schedule CHECK (at IS NULL OR "on" IS NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_recurrence_on_or_at CHECK (recurrence_rule IS NULL OR at IS NOT NULL OR "on" IS NOT NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_scheduled CHECK ((recurrence_rule IS NULL AND TYPE NOT IN ('task', 'event')) OR at IS NOT NULL OR "on" IS NOT NULL);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT activity_no_complete_recurrence CHECK (recurrence_rule IS NULL OR "done_at" IS NULL);

CREATE INDEX idx_activity_priority_id ON "public"."activity" ("priority_id");

CREATE INDEX idx_activity_path ON "public"."activity" USING gist ("path");

CREATE INDEX idx_activity_at ON "public"."activity" USING gist ("at");

CREATE INDEX idx_activity_on ON "public"."activity" USING gist ("on");

CREATE INDEX idx_activity_occurrence ON "public"."activity_exception" ("activity_id", "occurrence");

CREATE INDEX idx_activity_done_at ON "public"."activity" ("done_at");

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity_exception" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

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

CREATE OR REPLACE FUNCTION public.propagate_mentions_to_parent ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    parent_path ltree;
BEGIN
    -- Skip if this is already a top-level activity
    IF nlevel (NEW.path) = 1 THEN
        RETURN NEW;
    END IF;
    -- Skip if no mentions
    IF NEW.mentions IS NULL OR array_length(NEW.mentions, 1) IS NULL THEN
        RETURN NEW;
    END IF;
    -- Get top-level path (first segment only)
    parent_path := subpath (NEW.path, 0, 1);
    -- Update parent activity with deduplicated mentions
    -- Silently skips if parent not found (UPDATE affects 0 rows)
    UPDATE
        public.activity
    SET
        mentions = ARRAY ( SELECT DISTINCT
                unnest(COALESCE(mentions, ARRAY[]::uuid[]) || NEW.mentions))
    WHERE
        path = parent_path
        AND priority_id = NEW.priority_id
        AND archived_at IS NULL;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER activity_propagate_mentions_to_parent
    AFTER INSERT OR UPDATE OF mentions ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.propagate_mentions_to_parent ();

