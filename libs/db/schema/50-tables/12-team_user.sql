CREATE TABLE "public"."team_user" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "team_id" bigint NOT NULL REFERENCES team ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "role" team_role NOT NULL DEFAULT 'member',
    "archived_at" timestamp with time zone,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE (team_id, user_id)
);

CREATE INDEX idx_team_user_user_id ON "public"."team_user" ("user_id");
CREATE INDEX idx_team_user_team_id ON "public"."team_user" ("team_id");
CREATE INDEX idx_team_user_seq ON "public"."team_user" ("seq");

CREATE TRIGGER set_team_user_seq
    BEFORE INSERT OR UPDATE ON "public"."team_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq ();
