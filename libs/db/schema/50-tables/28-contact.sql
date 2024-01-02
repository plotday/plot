CREATE TABLE "public"."contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "is_self" boolean NOT NULL DEFAULT FALSE,
    "email" text NOT NULL CHECK (is_lower (email)),
    "name" text,
    "domain_id" bigint REFERENCES "domain" ON DELETE SET NULL,
    "avatar_url" text,
    CONSTRAINT contact_user_email_unique UNIQUE NULLS NOT DISTINCT (user_id, email)
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

