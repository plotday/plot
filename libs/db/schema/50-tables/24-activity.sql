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
    "assignee_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "deleted_at" timestamp with time zone,
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
    "source" jsonb
);

CREATE TABLE "public"."activity_exception" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_by" integer NOT NULL DEFAULT 0,
    "deleted_at" timestamp with time zone,
    "activity_id" uuid NOT NULL REFERENCES public.activity (id),
    "occurrence" text NOT NULL,
    -- overrides the root activity's fields
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "title" text,
    "note" text,
    "source" jsonb
);

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

CREATE OR REPLACE FUNCTION update_author_id ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.author_id = COALESCE(user_contact_id (), NEW.author_id);
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER set_activity_author_id
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_author_id ();

CREATE TRIGGER activity_change_api_call
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION public.notify_internal_api_for_activity ();

