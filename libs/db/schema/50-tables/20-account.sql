CREATE TABLE "public"."account" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "email" text NOT NULL CHECK (is_lower ("email")),
    "credentials" jsonb,
    "contact_sync_state" jsonb,
    CONSTRAINT account_user_id_email_key UNIQUE (user_id, email)
);

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE INDEX account_user_id_idx ON public.account USING btree (user_id);

CREATE TRIGGER set_account_updated_at
    BEFORE UPDATE ON "public"."account"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

