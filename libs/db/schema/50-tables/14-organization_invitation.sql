CREATE TABLE "public"."organization_invitation" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "organization_id" bigint NOT NULL REFERENCES organization ON DELETE CASCADE,
    "email" text NOT NULL CHECK ("email" = lower("email")),
    "role" organization_role NOT NULL DEFAULT 'member',
    "invited_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    UNIQUE (organization_id, email)
);

CREATE INDEX idx_organization_invitation_email ON "public"."organization_invitation" ("email");
