-- Create "email_claim" table
CREATE TABLE "public"."email_claim" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "user_id" uuid NOT NULL,
  "email" text NOT NULL,
  "code" text NOT NULL,
  "attempts" integer NOT NULL DEFAULT 0,
  "expires_at" timestamptz NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "email_claim_user_email_unique" UNIQUE ("user_id", "email"),
  CONSTRAINT "email_claim_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "email_claim_email_check" CHECK (email = lower(email))
);
