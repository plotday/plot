-- Create "default_priority_user_id" function
CREATE FUNCTION "public"."default_priority_user_id" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := NEW.created_by;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "default_priority_user_id"
CREATE TRIGGER "default_priority_user_id" BEFORE INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."default_priority_user_id"();
-- Add user_id as nullable first so existing rows can be backfilled before
-- the NOT NULL constraint is set.
ALTER TABLE "public"."priority"
    ADD COLUMN "user_id" uuid,
    ADD CONSTRAINT "priority_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;

-- Backfill: prefer the personal priority_user owner, fall back to the
-- creator. Every existing priority ends up with a non-null user_id.
UPDATE "public"."priority" p
SET user_id = COALESCE(
    (
        SELECT pu.user_id
        FROM "public"."priority_user" pu
        WHERE pu.priority_id = p.id AND pu.personal = TRUE
        LIMIT 1
    ),
    p.created_by
);

-- Now make the column NOT NULL.
ALTER TABLE "public"."priority" ALTER COLUMN "user_id" SET NOT NULL;

-- Create index "idx_priority_user_id" to table: "priority"
CREATE INDEX "idx_priority_user_id" ON "public"."priority" ("user_id");
