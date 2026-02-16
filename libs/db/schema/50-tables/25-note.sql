CREATE TABLE "public"."note" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "source_created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "archived_at" timestamp with time zone,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "content" text, -- markdown
    "links" jsonb,
    "key" text,
    "mentions" uuid[],
    "re_note_id" uuid REFERENCES public.note ON DELETE SET NULL
);

COMMENT ON COLUMN "public"."note"."source_created_at" IS 'When this note was originally created in its source system (e.g., email sent date, comment creation date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the note entered Plot''s database.';

COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by twists on behalf of contacts or users, this is the contact/user. For notes created directly by users or twists, this is the user/twist ID.';

COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or priority_twist_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of actor IDs (user_id, contact_id, or priority_twist_id) that are mentioned in this note via @-mentions.';

COMMENT ON COLUMN "public"."note"."key" IS 'External identifier for deduplication and sync within an activity. Provided as a top-level field in the Note type. Indexed for efficient lookups. Used with activity_id for upsert behavior, allowing notes to be idempotently created or updated by external key (e.g., "description" for Jira issue descriptions).';

-- Ensure one note per key per activity
-- No WHERE clause needed: NULL != NULL allows multiple notes when key is null
CREATE UNIQUE INDEX note_activity_key_unique ON "public"."note" ("activity_id", "key");

-- Index for efficient key lookups
CREATE INDEX idx_note_key ON "public"."note" ("key")
WHERE
    key IS NOT NULL;

-- Index for FK lookups
CREATE INDEX idx_note_activity_id ON "public"."note" ("activity_id");

-- Index for ordering by created_at within an activity
CREATE INDEX idx_note_created_at ON "public"."note" ("activity_id", "created_at");

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_note_updated_at ON "public"."note" ("updated_at");

-- Composite index for common join + filter pattern in user_activity and other views
CREATE INDEX idx_note_activity_archived ON "public"."note" ("activity_id", "archived_at");

-- Support unread calculation filters (n.author_id <> c.id with date comparisons)
-- Enhanced to include created_at for efficient date filtering in unread_check LATERAL join
CREATE INDEX idx_note_author_activity ON "public"."note" ("activity_id", "author_id", "created_at")
WHERE
    archived_at IS NULL;

-- Support lookup of replies to a specific note
CREATE INDEX idx_note_re_note_id ON "public"."note" ("re_note_id")
WHERE
    re_note_id IS NOT NULL;

-- Support mention array queries in user_activity view (mentions @> ARRAY[user_id])
CREATE INDEX idx_note_mentions ON "public"."note" USING gin ("mentions")
WHERE
    mentions IS NOT NULL AND archived_at IS NULL;

CREATE TRIGGER set_note_updated_at
    BEFORE INSERT OR UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_note_created_at
    BEFORE INSERT ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_note_author_and_created_by
    BEFORE INSERT ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

-- Function to update activity's last_note_created_at and activity_read when notes change
CREATE OR REPLACE FUNCTION public.update_activity_on_note_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the activity read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this activity to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.activity_id::text));

        -- Upsert activity_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO activity_read (user_id, activity_id, read_at)
        SELECT
            NEW.created_by,
            NEW.activity_id,
            NEW.created_at
        WHERE
            -- Only insert if created_by is an actual user from public."user"
            EXISTS (
                SELECT
                    1
                FROM
                    public."user"
                WHERE
                    id = NEW.created_by)
            AND NOT EXISTS (
                -- Check if any other user created notes since this user's last read_at
                SELECT
                    1
                FROM
                    note n
                LEFT JOIN activity_read ar ON ar.user_id = NEW.created_by
                    AND ar.activity_id = NEW.activity_id
            WHERE
                n.activity_id = NEW.activity_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            activity_id)
            DO UPDATE SET
                read_at = NEW.created_at,
                updated_at = now()
            WHERE
                -- Only update if still no other users have notes since current read_at
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE
                        n.activity_id = NEW.activity_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > activity_read.read_at);
        -- Update activity's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            activity
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.activity_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

-- Trigger on note INSERT and DELETE (not UPDATE of content)
CREATE TRIGGER update_activity_last_note_created_at_trigger
    AFTER INSERT OR DELETE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_activity_on_note_change ();

-- Trigger on UPDATE only when draft or archived_at changes
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change
    AFTER UPDATE OF draft,
    archived_at ON "public"."note"
    FOR EACH ROW
    WHEN ((OLD.draft IS DISTINCT FROM NEW.draft OR OLD.archived_at IS DISTINCT FROM NEW.archived_at))
    EXECUTE FUNCTION update_activity_on_note_change ();
