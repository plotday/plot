CREATE TABLE "public"."schedule_contact" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "schedule_id" uuid NOT NULL REFERENCES public.schedule (id) ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES public.contact (id) ON DELETE CASCADE,
    "status" text CHECK (status IN ('attend', 'skip')),
    "role" text NOT NULL DEFAULT 'required' CHECK (role IN ('organizer', 'required', 'optional')),
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT schedule_contact_unique UNIQUE (schedule_id, contact_id)
);

CREATE INDEX idx_schedule_contact_schedule_id ON "public"."schedule_contact" ("schedule_id");

CREATE INDEX idx_schedule_contact_contact_id ON "public"."schedule_contact" ("contact_id");

CREATE INDEX idx_schedule_contact_updated_at ON "public"."schedule_contact" ("updated_at");

CREATE INDEX idx_schedule_contact_seq ON "public"."schedule_contact" ("seq");

CREATE TRIGGER set_schedule_contact_updated_at
    BEFORE INSERT OR UPDATE ON "public"."schedule_contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_schedule_contact_created_at
    BEFORE INSERT ON "public"."schedule_contact"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
