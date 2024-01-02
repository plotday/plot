CREATE TABLE "public"."rule" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    -- matching fields (AND for a single row, OR across rows)
    "series" text,
    "name" text,
    "invitees" text[],
    "invitee_domain" text,
    "calendar_id" bigint REFERENCES calendar ON DELETE CASCADE,
    "internal" event_internal,
    "type" event_type,
    -- overrides
    "activity_id" bigint REFERENCES activity ON DELETE CASCADE,
    CONSTRAINT rule_unique UNIQUE NULLS NOT DISTINCT (user_id, series, name, invitees, invitee_domain, calendar_id, internal, type)
);

ALTER TABLE "public"."rule" ENABLE ROW LEVEL SECURITY;

CREATE INDEX rule_user_id_key ON public.rule USING btree (user_id);

ALTER publication supabase_realtime
    ADD TABLE public.rule;

