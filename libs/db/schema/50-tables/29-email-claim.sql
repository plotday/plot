CREATE TABLE "public"."email_claim" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "user_id" uuid NOT NULL REFERENCES "public"."user" ("id") ON DELETE CASCADE,
    "email" text NOT NULL CHECK (email = lower(email)),
    "code" text NOT NULL,
    "attempts" integer NOT NULL DEFAULT 0,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT email_claim_user_email_unique UNIQUE (user_id, email)
);
