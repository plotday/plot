CREATE TABLE "public"."activity" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "path" ltree NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25,
    CONSTRAINT user_path_unique UNIQUE (user_id, path)
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE INDEX activity_path_idx ON "public"."activity" USING GIST (user_id, path);

