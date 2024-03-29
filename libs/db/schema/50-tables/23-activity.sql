CREATE TABLE "public"."activity" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" bigint NOT NULL REFERENCES context ON DELETE CASCADE,
    "name" text NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE INDEX activity_user_id ON public.activity USING btree (user_id);

