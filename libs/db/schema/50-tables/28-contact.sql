CREATE TABLE "public"."contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "email" text NOT NULL CHECK (is_lower (email)),
    "name" text,
    "avatar_url" text,
    CONSTRAINT contact_user_email_unique UNIQUE NULLS NOT DISTINCT (user_id, email)
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

