CREATE TABLE "public"."activity_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid NOT NULL REFERENCES activity ON DELETE CASCADE,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    UNIQUE ("user_id", "activity_id", "tag_id")
);

ALTER TABLE "public"."activity_tag" ENABLE ROW LEVEL SECURITY;

CREATE INDEX ON "public"."activity_tag" (activity_id, tag_id)
WHERE
    deleted_at IS NULL;

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE UPDATE ON "public"."activity_tag"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

