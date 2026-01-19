CREATE TABLE "public"."note_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "note_id" uuid NOT NULL REFERENCES note ON DELETE CASCADE,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    UNIQUE NULLS NOT DISTINCT ("actor_id", "note_id", "tag_id")
);

ALTER TABLE "public"."note_tag" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_note_tag_note_id ON "public"."note_tag" (note_id, tag_id)
WHERE
    archived_at IS NULL;

-- Full index on note_id to support GROUP BY aggregation in note_tags view
-- note_tags view aggregates ALL rows (including archived), so partial index above isn't sufficient
CREATE INDEX idx_note_tag_note_id_full ON "public"."note_tag" ("note_id");

CREATE TRIGGER set_note_tag_updated_at
    BEFORE INSERT OR UPDATE ON "public"."note_tag"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

