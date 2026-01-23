CREATE TABLE "public"."priority_invitation" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7() NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES public.contact ON DELETE CASCADE,
    "invited_by" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    CONSTRAINT priority_invitation_unique UNIQUE (priority_id, contact_id)
);

ALTER TABLE "public"."priority_invitation" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_priority_invitation_priority ON priority_invitation (priority_id)
WHERE
    archived_at IS NULL;

CREATE INDEX idx_priority_invitation_contact ON priority_invitation (contact_id)
WHERE
    archived_at IS NULL;

CREATE TRIGGER set_priority_invitation_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_invitation"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

