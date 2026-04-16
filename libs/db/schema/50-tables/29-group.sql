CREATE TABLE "public"."group" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "name" text NOT NULL,
    "type" group_type NOT NULL DEFAULT 'private',
    "join_policy" group_join_policy NOT NULL DEFAULT 'member',
    "team_id" bigint REFERENCES team ON DELETE SET NULL,
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "auto_maintained" boolean NOT NULL DEFAULT FALSE,
    "auto_team_admin_team_id" bigint REFERENCES team ON DELETE CASCADE,
    "auto_publisher_id" bigint REFERENCES publisher ON DELETE CASCADE
);

CREATE INDEX idx_group_team_id ON "public"."group" ("team_id")
WHERE
    team_id IS NOT NULL;

CREATE INDEX idx_group_updated_at ON "public"."group" ("updated_at");

CREATE UNIQUE INDEX idx_group_auto_team ON "public"."group" ("team_id")
WHERE
    auto_maintained = TRUE
    AND team_id IS NOT NULL
    AND auto_team_admin_team_id IS NULL;

CREATE UNIQUE INDEX idx_group_auto_team_admin ON "public"."group" ("auto_team_admin_team_id")
WHERE
    auto_maintained = TRUE
    AND auto_team_admin_team_id IS NOT NULL;

CREATE UNIQUE INDEX idx_group_auto_publisher ON "public"."group" ("auto_publisher_id")
WHERE
    auto_maintained = TRUE
    AND auto_publisher_id IS NOT NULL;

CREATE UNIQUE INDEX idx_group_auto_everyone ON "public"."group" ("auto_maintained")
WHERE
    auto_maintained = TRUE
    AND team_id IS NULL
    AND auto_publisher_id IS NULL;

CREATE TRIGGER set_group_updated_at
    BEFORE INSERT OR UPDATE ON "public"."group"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_group_created_at
    BEFORE INSERT ON "public"."group"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."group" IS 'Named groups of contacts. Groups can be added to threads for dynamic visibility — adding a member retroactively grants access to all threads the group is on.';
COMMENT ON COLUMN "public"."group"."auto_maintained" IS 'TRUE for system-managed groups (Everyone, team groups). Membership is maintained by triggers and cannot be modified via API.';

CREATE TABLE "public"."group_member" (
    "group_id" uuid NOT NULL REFERENCES "group" ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES contact ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("group_id", "contact_id")
);

CREATE INDEX idx_group_member_contact_id ON "public"."group_member" ("contact_id");

CREATE TRIGGER set_group_member_updated_at
    BEFORE INSERT OR UPDATE ON "public"."group_member"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_group_member_created_at
    BEFORE INSERT ON "public"."group_member"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TABLE "public"."group_admin" (
    "group_id" uuid NOT NULL REFERENCES "group" ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("group_id", "user_id")
);

CREATE INDEX idx_group_admin_user_id ON "public"."group_admin" ("user_id");
