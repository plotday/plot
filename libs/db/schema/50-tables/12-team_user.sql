CREATE TABLE "public"."team_user" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "team_id" bigint NOT NULL REFERENCES team ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "role" team_role NOT NULL DEFAULT 'member',
    UNIQUE (team_id, user_id)
);

CREATE INDEX idx_team_user_user_id ON "public"."team_user" ("user_id");
CREATE INDEX idx_team_user_team_id ON "public"."team_user" ("team_id");
