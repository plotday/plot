-- Repair prod divergence from migration 20260409114623_thread_note_visibility_redesign.
--
-- That migration originally wrote `access = 'restricted'` and was applied to prod
-- on 2026-04-09 14:27:21 UTC. The file was later edited in place (commit c0566d91c)
-- to rename 'restricted' → 'private' so schema files and the migration agree, but
-- prod was never re-migrated. Result: prod's check constraint and trigger still
-- reject 'private', so every connector saveLink (which now passes access:"private")
-- fails the constraint and silently aborts the upsert.
--
-- This migration brings prod in line with the current schema files. Local databases
-- that already ran the rewritten migration are no-ops:
--   - the UPDATE matches zero rows
--   - DROP CONSTRAINT IF EXISTS + recreate is idempotent
--   - CREATE OR REPLACE FUNCTION is idempotent

-- 1. Migrate existing rows to the new value.
UPDATE "public"."thread" SET access = 'private' WHERE access = 'restricted';

-- 2. Replace the check constraint to accept 'private' instead of 'restricted'.
ALTER TABLE "public"."thread" DROP CONSTRAINT IF EXISTS "thread_access_valid";
ALTER TABLE "public"."thread" ADD CONSTRAINT "thread_access_valid"
    CHECK (access = ANY (ARRAY['public'::text, 'members'::text, 'private'::text]));

-- 3. Replace the default-icon trigger function so it compares against 'private'.
CREATE OR REPLACE FUNCTION "public"."apply_default_thread_icon" ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_default_icon text;
BEGIN
    -- Apply when icon is unset or is a default sub-type auto-assigned by the app
    IF (NEW.icon IS NULL OR NEW.icon IN ('notes', 'discussion')) AND NEW.access != 'private' THEN
        SELECT
            default_thread_icon INTO v_default_icon
        FROM
            priority
        WHERE
            id = NEW.priority_id;
        IF v_default_icon IS NOT NULL THEN
            NEW.icon := v_default_icon;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- 4. Refresh column comments to match schema files.
COMMENT ON COLUMN "public"."thread"."access" IS 'Access level: public (everyone in priority), members (members only), private (author + access_contacts only). Default is members, which equals public in priorities without viewers.';
COMMENT ON COLUMN "public"."thread"."access_contacts" IS 'Array of contact_ids granted additional access beyond the base access level. For members access, these are viewer-role contacts. For private access, these are the only contacts who can see the thread (besides the author).';
