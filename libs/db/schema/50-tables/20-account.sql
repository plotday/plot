CREATE TABLE "public"."account" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "email" text NOT NULL CHECK (is_lower ("email")),
    "credentials" jsonb,
    "contact_sync_state" jsonb,
    "updated_by" integer NOT NULL DEFAULT 0,
    CONSTRAINT account_user_id_email_key UNIQUE (user_id, email)
);

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE INDEX account_user_id_idx ON public.account USING btree (user_id);

CREATE TRIGGER set_account_updated_at
    BEFORE UPDATE ON "public"."account"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION public.notify_user_for_account ()
    RETURNS TRIGGER
    SECURITY DEFINER
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM
        realtime.send (jsonb_build_object('table', 'account', 'updated_by', COALESCE(NEW.updated_by, OLD.updated_by)), -- JSONB Payload
            'sync', -- Event name
            'user:' || COALESCE(NEW.user_id, OLD.user_id)::text, -- Topic
            FALSE -- Public / Private flag
);
    RETURN NULL;
END;
$$;

CREATE TRIGGER handle_account_changes
    AFTER INSERT OR UPDATE ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION notify_user_for_account ();

