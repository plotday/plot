CREATE TABLE "public"."activity_tag" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "activity_id" uuid NOT NULL REFERENCES activity ON DELETE CASCADE,
    "occurrence" text,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    UNIQUE NULLS NOT DISTINCT ("actor_id", "activity_id", "occurrence", "tag_id")
);

COMMENT ON COLUMN "public"."activity_tag"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';

CREATE INDEX idx_activity_tag_activity_id ON "public"."activity_tag" (activity_id, tag_id)
WHERE
    archived_at IS NULL;

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE INSERT OR UPDATE ON "public"."activity_tag"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

