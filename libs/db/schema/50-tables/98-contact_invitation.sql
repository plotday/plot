CREATE TABLE "public"."contact_invitation" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "contact_id" uuid NOT NULL,
    "token" text NOT NULL UNIQUE,
    "sent_at" timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contact_invitation_contact_unique UNIQUE (contact_id)
);

-- RLS enabled with NO policies = only service_role can access
ALTER TABLE "public"."contact_invitation" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_contact_invitation_token ON contact_invitation (token);

ALTER TABLE "public"."contact_invitation"
    ADD CONSTRAINT "contact_invitation_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."contact_invitation" VALIDATE CONSTRAINT "contact_invitation_contact_id_fkey";
