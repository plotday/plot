CREATE TABLE "public"."thread_tag" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "thread_id" uuid NOT NULL REFERENCES thread ON DELETE CASCADE,
    "occurrence" text,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    UNIQUE NULLS NOT DISTINCT ("actor_id", "thread_id", "occurrence", "tag_id")
);

COMMENT ON COLUMN "public"."thread_tag"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';

CREATE INDEX idx_thread_tag_thread_id ON "public"."thread_tag" (thread_id, tag_id)
WHERE
    archived_at IS NULL;

CREATE INDEX idx_thread_tag_thread_id_all ON "public"."thread_tag" (thread_id);

CREATE TRIGGER set_thread_tag_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_tag"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
