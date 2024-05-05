CREATE TABLE "public"."context" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "path" ltree NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25,
    CONSTRAINT user_path_unique UNIQUE (user_id, path)
);

ALTER TABLE "public"."context" ENABLE ROW LEVEL SECURITY;

CREATE INDEX context_path_idx ON "public"."context" USING GIST (user_id, path);

CREATE INDEX context_user_id ON public.context USING btree (user_id);

