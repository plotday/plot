CREATE TABLE "public"."topic" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    "name" text NOT NULL,
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "team_id" bigint REFERENCES team ON DELETE SET NULL,
    "announce" boolean NOT NULL DEFAULT FALSE,
    "join_policy" topic_join_policy NOT NULL DEFAULT 'open',
    "auto_maintained" boolean NOT NULL DEFAULT FALSE,
    "key" text,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT topic_key_unique UNIQUE ("key")
);

CREATE INDEX idx_topic_seq ON "public"."topic" ("seq");
CREATE INDEX idx_topic_updated_at ON "public"."topic" ("updated_at");
CREATE INDEX idx_topic_team_id ON "public"."topic" ("team_id") WHERE team_id IS NOT NULL;
CREATE UNIQUE INDEX idx_topic_auto_global ON "public"."topic" ("key")
    WHERE auto_maintained = TRUE AND team_id IS NULL;

CREATE TRIGGER set_topic_updated_at
    BEFORE INSERT OR UPDATE ON "public"."topic"
    FOR EACH ROW EXECUTE FUNCTION update_seq_and_updated_at ();
CREATE TRIGGER set_topic_created_at
    BEFORE INSERT ON "public"."topic"
    FOR EACH ROW EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."topic" IS 'Plot-only channel that owns a stream of threads (thread.topic_id). Membership is composed from topic_contact + topic_group members, minus topic_member_optout. Adding a member retroactively grants access to every thread in the topic.';
COMMENT ON COLUMN "public"."topic"."auto_maintained" IS 'TRUE for system-managed topics (Plot Updates). Membership composition is maintained by triggers and cannot be modified via API.';
COMMENT ON COLUMN "public"."topic"."key" IS 'Stable identifier for system-managed topics (e.g. ''@plot.updates''). Nullable; user-created topics have no key.';

-- Topic membership/governance child tables. Rows are add/remove only (no
-- per-row mutation), so unlike group_member they intentionally carry no
-- updated_at column.
CREATE TABLE "public"."topic_contact" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES contact ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "contact_id")
);
CREATE INDEX idx_topic_contact_contact_id ON "public"."topic_contact" ("contact_id");

CREATE TABLE "public"."topic_group" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "group_id" uuid NOT NULL REFERENCES "group" ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "group_id")
);
CREATE INDEX idx_topic_group_group_id ON "public"."topic_group" ("group_id");

CREATE TABLE "public"."topic_admin" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "user_id")
);
CREATE INDEX idx_topic_admin_user_id ON "public"."topic_admin" ("user_id");

CREATE TABLE "public"."topic_member_optout" (
    "topic_id" uuid NOT NULL REFERENCES topic ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("topic_id", "user_id")
);
CREATE INDEX idx_topic_member_optout_user_id ON "public"."topic_member_optout" ("user_id");
