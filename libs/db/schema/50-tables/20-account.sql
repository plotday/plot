CREATE TABLE "public"."account" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "email" text NOT NULL,
    "credentials" jsonb,
    "domain_id" bigint REFERENCES "domain" ON DELETE SET NULL,
    "contact_sync_state" jsonb,
    CONSTRAINT account_user_id_email_key UNIQUE (user_id, email)
);

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE INDEX account_user_id_idx ON public.account USING btree (user_id);

