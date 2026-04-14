CREATE TABLE "public"."topic" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "name" text NOT NULL,
    "type" topic_type NOT NULL DEFAULT 'private',
    "join_policy" topic_join_policy NOT NULL DEFAULT 'member',
    "team_id" bigint REFERENCES team ON DELETE SET NULL,
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "auto_maintained" boolean NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_topic_team_id ON "public"."topic" ("team_id")
WHERE
    team_id IS NOT NULL;

CREATE INDEX idx_topic_updated_at ON "public"."topic" ("updated_at");

CREATE UNIQUE INDEX idx_topic_auto_team ON "public"."topic" ("team_id")
WHERE
    auto_maintained = TRUE
    AND team_id IS NOT NULL;

CREATE UNIQUE INDEX idx_topic_auto_everyone ON "public"."topic" ("auto_maintained")
WHERE
    auto_maintained = TRUE
    AND team_id IS NULL;

CREATE TRIGGER set_topic_updated_at
    BEFORE INSERT OR UPDATE ON "public"."topic"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_topic_created_at
    BEFORE INSERT ON "public"."topic"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."topic" IS 'Named groups of contacts. Topics can be added to threads for dynamic group visibility — adding a member retroactively grants access to all threads the topic is on.';
COMMENT ON COLUMN "public"."topic"."auto_maintained" IS 'TRUE for system-managed topics (Everyone, team topics). Membership is maintained by triggers and cannot be modified via API.';

CREATE TABLE "public"."topic_member" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES contact ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "contact_id")
);

CREATE INDEX idx_topic_member_contact_id ON "public"."topic_member" ("contact_id");

CREATE TRIGGER set_topic_member_updated_at
    BEFORE INSERT OR UPDATE ON "public"."topic_member"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_topic_member_created_at
    BEFORE INSERT ON "public"."topic_member"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TABLE "public"."topic_admin" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "user_id")
);

CREATE INDEX idx_topic_admin_user_id ON "public"."topic_admin" ("user_id");
