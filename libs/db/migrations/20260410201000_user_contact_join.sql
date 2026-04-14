-- Create "user_contact" table
CREATE TABLE "public"."user_contact" (
  "user_id" uuid NOT NULL,
  "contact_id" uuid NOT NULL,
  "linked" boolean NOT NULL DEFAULT false,
  "primary" boolean NOT NULL DEFAULT false,
  "source" text NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  PRIMARY KEY ("user_id", "contact_id"),
  CONSTRAINT "user_contact_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contact" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "user_contact_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "user_contact_primary_requires_linked" CHECK ((NOT "primary") OR linked)
);
-- Create index "idx_user_contact_contact_id" to table: "user_contact"
CREATE INDEX "idx_user_contact_contact_id" ON "public"."user_contact" ("contact_id");
-- Create index "idx_user_contact_user_id_linked" to table: "user_contact"
CREATE INDEX "idx_user_contact_user_id_linked" ON "public"."user_contact" ("user_id") WHERE ((linked = true) AND (archived_at IS NULL));
-- Create index "idx_user_contact_user_primary_unique" to table: "user_contact"
CREATE UNIQUE INDEX "idx_user_contact_user_primary_unique" ON "public"."user_contact" ("user_id") WHERE ("primary" = true);
-- Create "sync_user_contact_from_contact" function
CREATE FUNCTION "public"."sync_user_contact_from_contact" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Remove an old identity row if user_id changed (including to NULL)
    IF TG_OP = 'UPDATE' AND OLD.user_id IS NOT NULL
       AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
        DELETE FROM user_contact
        WHERE user_id = OLD.user_id
          AND contact_id = OLD.id
          AND linked = TRUE;
    END IF;

    -- Upsert the identity row for the current user_id, if any
    IF NEW.user_id IS NOT NULL THEN
        INSERT INTO user_contact (user_id, contact_id, linked, "primary", source, archived_at)
        VALUES (NEW.user_id, NEW.id, TRUE, COALESCE(NEW."primary", FALSE), 'self', NEW.archived_at)
        ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            linked = TRUE,
            "primary" = EXCLUDED."primary",
            source = COALESCE(user_contact.source, EXCLUDED.source),
            archived_at = EXCLUDED.archived_at,
            updated_at = now();
    END IF;

    RETURN NEW;
END;
$$;
-- Backfill user_contact identity rows from existing contact.user_id / contact.primary.
-- Runs before the sync trigger is attached to avoid double-work. Any contact that
-- is already linked (user_id IS NOT NULL) becomes a linked identity row. primary
-- carries over so "user".user_contact_id() keeps returning the same value.
INSERT INTO "public"."user_contact" (user_id, contact_id, linked, "primary", source, archived_at, created_at, updated_at)
SELECT
    c.user_id,
    c.id,
    TRUE,
    COALESCE(c."primary", FALSE),
    'self',
    c.archived_at,
    c.created_at,
    c.updated_at
FROM "public"."contact" c
WHERE c.user_id IS NOT NULL
ON CONFLICT (user_id, contact_id) DO NOTHING;
-- Create trigger "sync_user_contact_from_contact"
CREATE TRIGGER "sync_user_contact_from_contact" AFTER INSERT OR UPDATE OF "archived_at", "primary", "user_id" ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."sync_user_contact_from_contact"();
-- Create trigger "set_user_contact_created_at"
CREATE TRIGGER "set_user_contact_created_at" BEFORE INSERT ON "public"."user_contact" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_user_contact_updated_at"
CREATE TRIGGER "set_user_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."user_contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "user_contact_id" function
CREATE OR REPLACE FUNCTION "user"."user_contact_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT uc.contact_id
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;
$$;
-- Modify "user_contact_ids" function
CREATE OR REPLACE FUNCTION "user"."user_contact_ids" ("p_user_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;
$$;
