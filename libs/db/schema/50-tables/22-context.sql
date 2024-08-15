CREATE TABLE "public"."context" (
    "id" uuid PRIMARY KEY DEFAULT uuid_generate_v4 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "path" ltree NOT NULL,
    "order" text NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25,
    CONSTRAINT user_path_unique UNIQUE (user_id, path),
    CONSTRAINT user_parent_path_order_unique
    EXCLUDE USING gist (user_id WITH =, parent_path (path
) WITH =, "order" WITH =)
);

ALTER TABLE "public"."context" ENABLE ROW LEVEL SECURITY;

CREATE INDEX context_path_idx ON "public"."context" USING GIST (user_id, path);

CREATE INDEX context_user_id ON public.context USING btree (user_id);

CREATE TRIGGER set_context_modified_at
    BEFORE UPDATE ON "public"."context"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

