CREATE TABLE "public"."team_invitation" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "team_id" bigint NOT NULL REFERENCES team ON DELETE CASCADE,
    "email" text NOT NULL CHECK ("email" = lower("email")),
    "role" team_role NOT NULL DEFAULT 'member',
    "invited_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    UNIQUE (team_id, email)
);

CREATE INDEX idx_team_invitation_email ON "public"."team_invitation" ("email");
