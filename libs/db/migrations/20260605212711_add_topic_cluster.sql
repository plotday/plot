-- Create enum type "topic_join_policy"
CREATE TYPE "public"."topic_join_policy" AS ENUM ('open', 'admin');
-- Create "topic" table
CREATE TABLE "public"."topic" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "name" text NOT NULL,
  "created_by" uuid NOT NULL,
  "team_id" bigint NULL,
  "announce" boolean NOT NULL DEFAULT false,
  "join_policy" "public"."topic_join_policy" NOT NULL DEFAULT 'open',
  "auto_maintained" boolean NOT NULL DEFAULT false,
  "key" text NULL,
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "topic_key_unique" UNIQUE ("key"),
  CONSTRAINT "topic_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."team" ("id") ON UPDATE NO ACTION ON DELETE SET NULL
);
-- Create index "idx_topic_auto_global" to table: "topic"
CREATE UNIQUE INDEX "idx_topic_auto_global" ON "public"."topic" ("key") WHERE ((auto_maintained = true) AND (team_id IS NULL));
-- Create index "idx_topic_seq" to table: "topic"
CREATE INDEX "idx_topic_seq" ON "public"."topic" ("seq");
-- Create index "idx_topic_team_id" to table: "topic"
CREATE INDEX "idx_topic_team_id" ON "public"."topic" ("team_id") WHERE (team_id IS NOT NULL);
-- Create index "idx_topic_updated_at" to table: "topic"
CREATE INDEX "idx_topic_updated_at" ON "public"."topic" ("updated_at");
-- Set comment to table: "topic"
COMMENT ON TABLE "public"."topic" IS 'Plot-only channel that owns a stream of threads (thread.topic_id). Membership is composed from topic_contact + topic_group members, minus topic_member_optout. Adding a member retroactively grants access to every thread in the topic.';
-- Create "bump_topic_seq_from_new_table" function
CREATE FUNCTION "public"."bump_topic_seq_from_new_table" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM new_table);
    RETURN NULL;
END;
$$;
-- Create "topic_group" table
CREATE TABLE "public"."topic_group" (
  "topic_id" uuid NOT NULL,
  "group_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "group_id"),
  CONSTRAINT "topic_group_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."group" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_group_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_group_group_id" to table: "topic_group"
CREATE INDEX "idx_topic_group_group_id" ON "public"."topic_group" ("group_id");
-- Create trigger "bump_topic_seq_on_group_insert"
CREATE TRIGGER "bump_topic_seq_on_group_insert" AFTER INSERT ON "public"."topic_group" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_new_table"();
-- Create "topic_member_optout" table
CREATE TABLE "public"."topic_member_optout" (
  "topic_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "user_id"),
  CONSTRAINT "topic_member_optout_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_member_optout_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_member_optout_user_id" to table: "topic_member_optout"
CREATE INDEX "idx_topic_member_optout_user_id" ON "public"."topic_member_optout" ("user_id");
-- Create trigger "bump_topic_seq_on_optout_insert"
CREATE TRIGGER "bump_topic_seq_on_optout_insert" AFTER INSERT ON "public"."topic_member_optout" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_new_table"();
-- Create trigger "set_topic_created_at"
CREATE TRIGGER "set_topic_created_at" BEFORE INSERT ON "public"."topic" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_topic_updated_at"
CREATE TRIGGER "set_topic_updated_at" BEFORE INSERT OR UPDATE ON "public"."topic" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "bump_topic_seq_from_old_table" function
CREATE FUNCTION "public"."bump_topic_seq_from_old_table" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM old_table);
    RETURN NULL;
END;
$$;
-- Create "topic_admin" table
CREATE TABLE "public"."topic_admin" (
  "topic_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "user_id"),
  CONSTRAINT "topic_admin_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_admin_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_admin_user_id" to table: "topic_admin"
CREATE INDEX "idx_topic_admin_user_id" ON "public"."topic_admin" ("user_id");
-- Create trigger "bump_topic_seq_on_admin_delete"
CREATE TRIGGER "bump_topic_seq_on_admin_delete" AFTER DELETE ON "public"."topic_admin" REFERENCING OLD TABLE AS "old_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_old_table"();
-- Create trigger "bump_topic_seq_on_admin_insert"
CREATE TRIGGER "bump_topic_seq_on_admin_insert" AFTER INSERT ON "public"."topic_admin" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_new_table"();
-- Create trigger "bump_topic_seq_on_optout_delete"
CREATE TRIGGER "bump_topic_seq_on_optout_delete" AFTER DELETE ON "public"."topic_member_optout" REFERENCING OLD TABLE AS "old_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_old_table"();
-- Create "topic_contact" table
CREATE TABLE "public"."topic_contact" (
  "topic_id" uuid NOT NULL,
  "contact_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("topic_id", "contact_id"),
  CONSTRAINT "topic_contact_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contact" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "topic_contact_topic_id_fkey" FOREIGN KEY ("topic_id") REFERENCES "public"."topic" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_topic_contact_contact_id" to table: "topic_contact"
CREATE INDEX "idx_topic_contact_contact_id" ON "public"."topic_contact" ("contact_id");
-- Create trigger "bump_topic_seq_on_contact_delete"
CREATE TRIGGER "bump_topic_seq_on_contact_delete" AFTER DELETE ON "public"."topic_contact" REFERENCING OLD TABLE AS "old_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_old_table"();
-- Create trigger "bump_topic_seq_on_contact_insert"
CREATE TRIGGER "bump_topic_seq_on_contact_insert" AFTER INSERT ON "public"."topic_contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_new_table"();
-- Create trigger "bump_topic_seq_on_group_delete"
CREATE TRIGGER "bump_topic_seq_on_group_delete" AFTER DELETE ON "public"."topic_group" REFERENCING OLD TABLE AS "old_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_topic_seq_from_old_table"();
