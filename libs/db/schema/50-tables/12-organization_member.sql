CREATE TABLE "public"."organization_member" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "organization_id" bigint NOT NULL REFERENCES organization ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "role" organization_role NOT NULL DEFAULT 'member',
    UNIQUE (organization_id, user_id)
);

CREATE INDEX idx_organization_member_user_id ON "public"."organization_member" ("user_id");
CREATE INDEX idx_organization_member_organization_id ON "public"."organization_member" ("organization_id");
