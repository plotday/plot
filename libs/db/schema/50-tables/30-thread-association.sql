CREATE TABLE "public"."thread_association" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "parent_thread_id" uuid NOT NULL REFERENCES public.thread (id) ON DELETE CASCADE,
    "child_thread_id" uuid NOT NULL REFERENCES public.thread (id) ON DELETE CASCADE,
    "order" double precision NOT NULL,
    "archived_at" timestamptz
);

-- A child can only be actively associated with one parent at a time
CREATE UNIQUE INDEX thread_association_child_active_unique ON "public"."thread_association" ("child_thread_id")
WHERE
    archived_at IS NULL;

-- Unique active association per parent-child pair
CREATE UNIQUE INDEX thread_association_parent_child_unique ON "public"."thread_association" ("parent_thread_id", "child_thread_id")
WHERE
    archived_at IS NULL;

CREATE INDEX idx_thread_association_parent ON "public"."thread_association" ("parent_thread_id");

CREATE INDEX idx_thread_association_child ON "public"."thread_association" ("child_thread_id");

CREATE INDEX idx_thread_association_updated_at ON "public"."thread_association" ("updated_at");

CREATE TRIGGER set_thread_association_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_association"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_thread_association_created_at
    BEFORE INSERT ON "public"."thread_association"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
