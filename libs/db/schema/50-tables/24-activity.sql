CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "path" ltree NOT NULL,
    "order" double precision NOT NULL DEFAULT public.order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "pinned" boolean NOT NULL DEFAULT FALSE,
    "do_at" date,
    "done_at" timestamp with time zone,
    "note" text,
    "event_series" text
);

CREATE INDEX idx_activity_priority_id ON "public"."activity" ("priority_id");
CREATE INDEX idx_activity_path ON "public"."activity" USING gist ("path");
CREATE INDEX idx_activity_do_at ON "public"."activity" ("do_at");
CREATE INDEX idx_activity_done_at ON "public"."activity" ("done_at");

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_created_by
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();