-- Set comment to column: "key" on table: "note"
COMMENT ON COLUMN "public"."note"."key" IS 'External identifier for deduplication and sync within a thread. Provided as a top-level field in the Note type. Indexed for efficient lookups. Used with thread_id for upsert behavior, allowing notes to be idempotently created or updated by external key (e.g., "description" for Jira issue descriptions).';
-- Create "update_thread_on_note_change" function
CREATE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the thread read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this thread to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        -- Upsert thread_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO thread_read (user_id, thread_id, read_at)
        SELECT
            NEW.created_by,
            NEW.thread_id,
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
                LEFT JOIN thread_read ar ON ar.user_id = NEW.created_by
                    AND ar.thread_id = NEW.thread_id
            WHERE
                n.thread_id = NEW.thread_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            thread_id)
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
                        n.thread_id = NEW.thread_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > thread_read.read_at);
        -- Update thread's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            thread
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.thread_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Create trigger "update_thread_last_note_created_at_trigger"
CREATE TRIGGER "update_thread_last_note_created_at_trigger" AFTER DELETE OR INSERT ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."update_thread_on_note_change"();
-- Create trigger "update_thread_last_note_created_at_on_status_change"
CREATE TRIGGER "update_thread_last_note_created_at_on_status_change" AFTER UPDATE OF "archived_at", "draft" ON "public"."note" FOR EACH ROW WHEN ((old.draft IS DISTINCT FROM new.draft) OR (old.archived_at IS DISTINCT FROM new.archived_at)) EXECUTE FUNCTION "public"."update_thread_on_note_change"();
-- Set comment to column: "author_id" on table: "thread"
COMMENT ON COLUMN "public"."thread"."author_id" IS 'The actor to credit with creating this thread. For threads created by twists on behalf of contacts or users, this is the contact/user. For threads created directly by users or twists, this is the user/twist ID.';
-- Set comment to column: "created_by" on table: "thread"
COMMENT ON COLUMN "public"."thread"."created_by" IS 'The user_id or priority_twist_id that actually created this thread. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';
-- Set comment to column: "source" on table: "thread"
COMMENT ON COLUMN "public"."thread"."source" IS 'External source identifier for deduplication and sync. Provided as a top-level field in the Thread type (not stored in meta). Indexed for efficient lookups. Used with source_priority_root for upsert behavior.';
-- Set comment to column: "created_by_twist_id" on table: "thread"
COMMENT ON COLUMN "public"."thread"."created_by_twist_id" IS 'The twist definition ID (twist_admin.id) that created this thread. Null for user-created threads. No longer used in unique constraint (replaced by source_priority_root).';
-- Set comment to column: "pick_priority" on table: "thread"
COMMENT ON COLUMN "public"."thread"."pick_priority" IS 'The PickPriorityConfig used to automatically select this thread''s priority. Null if priority was explicitly specified. Used when moving threads to find similar threads to move. Not exposed to app or API.';
-- Set comment to column: "last_note_created_at" on table: "thread"
COMMENT ON COLUMN "public"."thread"."last_note_created_at" IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for unread status in user_thread and user_priority_unread views.';
-- Set comment to column: "source_created_at" on table: "thread"
COMMENT ON COLUMN "public"."thread"."source_created_at" IS 'When this thread was originally created in its source system (e.g., GitHub issue creation date, email sent date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the thread entered Plot''s database.';
-- Set comment to column: "last_note_source_created_at" on table: "thread"
COMMENT ON COLUMN "public"."thread"."last_note_source_created_at" IS 'Cached MAX(note.source_created_at) for non-draft, non-archived notes. Maintained by trigger. Used for display, sorting, and range_at computation in user_thread view.';
-- Create "ensure_assignee_priority_contact" function
CREATE FUNCTION "public"."ensure_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a priority_twist)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (NEW.priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "ensure_assignee_priority_contact_trigger"
CREATE TRIGGER "ensure_assignee_priority_contact_trigger" AFTER INSERT OR UPDATE OF "assignee_id", "priority_id" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_assignee_priority_contact"();
-- Create "sync_twist_for_thread" function
CREATE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft rows are creates
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft threads (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft rows are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published threads)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for the twist that created this thread
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'thread', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_thread_insert"
CREATE TRIGGER "twist_sync_thread_insert" AFTER INSERT ON "public"."thread" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_thread"();
-- Create "sync_user_for_thread" function
CREATE FUNCTION "public"."sync_user_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to affected priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_insert"
CREATE TRIGGER "user_sync_thread_insert" AFTER INSERT ON "public"."thread" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread"();
-- Create trigger "set_thread_author_and_created_by"
CREATE TRIGGER "set_thread_author_and_created_by" BEFORE INSERT ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."update_author_and_created_by"();
-- Create trigger "set_thread_created_at"
CREATE TRIGGER "set_thread_created_at" BEFORE INSERT ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "set_thread_order_on_start" function
CREATE FUNCTION "public"."set_thread_order_on_start" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- If thread has a start time (at or on) but no explicit order,
    -- set order to current timestamp for stable sorting
    IF (NEW.at IS NOT NULL OR NEW."on" IS NOT NULL) AND NEW."order" IS NULL THEN
        NEW."order" := public.order_first ();
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_thread_order_on_start_trigger"
CREATE TRIGGER "set_thread_order_on_start_trigger" BEFORE INSERT OR UPDATE ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."set_thread_order_on_start"();
-- Create "set_thread_source_priority_root" function
CREATE FUNCTION "public"."set_thread_source_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = NEW.priority_id;
        -- Extract the root element (first segment) of the priority path
        IF priority_path IS NOT NULL THEN
            NEW.source_priority_root := subpath (priority_path, 0, 1);
        END IF;
    ELSE
        -- Clear source_priority_root when source is null
        NEW.source_priority_root := NULL;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_thread_source_priority_root_trigger"
CREATE TRIGGER "set_thread_source_priority_root_trigger" BEFORE INSERT OR UPDATE OF "priority_id", "source" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."set_thread_source_priority_root"();
-- Create trigger "set_thread_updated_at"
CREATE TRIGGER "set_thread_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_thread_update"
CREATE TRIGGER "twist_sync_thread_update" AFTER UPDATE ON "public"."thread" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_thread"();
-- Create trigger "user_sync_thread_update"
CREATE TRIGGER "user_sync_thread_update" AFTER UPDATE ON "public"."thread" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread"();
-- Create trigger "enforce_thread_draft_rules_trigger"
CREATE TRIGGER "enforce_thread_draft_rules_trigger" BEFORE UPDATE ON "public"."thread" FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft) EXECUTE FUNCTION "public"."enforce_draft_rules"();
-- Create "protect_thread_created_by" function
CREATE FUNCTION "public"."protect_thread_created_by" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- author_id is immutable: always preserve original value
    NEW.author_id := OLD.author_id;
    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            -- Derive created_by_twist_id from new created_by
            SELECT
                pt.twist_id INTO NEW.created_by_twist_id
            FROM
                priority_twist pt
            WHERE
                pt.id = NEW.created_by;
        END IF;
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
        NEW.created_by_twist_id := OLD.created_by_twist_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "protect_thread_created_by_trigger"
CREATE TRIGGER "protect_thread_created_by_trigger" BEFORE UPDATE ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."protect_thread_created_by"();
-- Create trigger "set_thread_exception_created_at"
CREATE TRIGGER "set_thread_exception_created_at" BEFORE INSERT ON "public"."thread_exception" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_thread_exception_updated_at"
CREATE TRIGGER "set_thread_exception_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_exception" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "sync_user_for_thread_read" function
CREATE FUNCTION "public"."sync_user_for_thread_read" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the reading user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread_read', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_read_insert"
CREATE TRIGGER "user_sync_thread_read_insert" AFTER INSERT ON "public"."thread_read" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_read"();
-- Create trigger "set_thread_read_updated_at"
CREATE TRIGGER "set_thread_read_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_read" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_thread_read_update"
CREATE TRIGGER "user_sync_thread_read_update" AFTER UPDATE ON "public"."thread_read" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_read"();
-- Create "sync_twist_for_thread_tag" function
CREATE FUNCTION "public"."sync_twist_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft threads
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected threads
    -- Only consider tags on non-draft threads
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this thread
        AND a.created_by = pct.id
    ORDER BY
        pct.id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'thread', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_thread_tag_insert"
CREATE TRIGGER "twist_sync_thread_tag_insert" AFTER INSERT ON "public"."thread_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_thread_tag"();
-- Create "sync_user_for_thread_tag" function
CREATE FUNCTION "public"."sync_user_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent thread's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_tag_insert"
CREATE TRIGGER "user_sync_thread_tag_insert" AFTER INSERT ON "public"."thread_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_tag"();
-- Create trigger "set_thread_tag_updated_at"
CREATE TRIGGER "set_thread_tag_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_tag" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_thread_tag_update"
CREATE TRIGGER "twist_sync_thread_tag_update" AFTER UPDATE ON "public"."thread_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_thread_tag"();
-- Create trigger "user_sync_thread_tag_update"
CREATE TRIGGER "user_sync_thread_tag_update" AFTER UPDATE ON "public"."thread_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_tag"();
-- Set comment to column: "on" on table: "thread_user_state"
COMMENT ON COLUMN "public"."thread_user_state"."on" IS 'Date range when this user wants to work on this thread. Start date determines scheduling: today or past = Do Now, future = Do Later.';
-- Create "sync_user_for_thread_user_state" function
CREATE FUNCTION "public"."sync_user_for_thread_user_state" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the owning user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread_user_state', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_thread_user_state_insert"
CREATE TRIGGER "user_sync_thread_user_state_insert" AFTER INSERT ON "public"."thread_user_state" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_user_state"();
-- Create trigger "set_thread_user_state_updated_at"
CREATE TRIGGER "set_thread_user_state_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_user_state" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_thread_user_state_update"
CREATE TRIGGER "user_sync_thread_user_state_update" AFTER UPDATE ON "public"."thread_user_state" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_user_state"();
-- Modify "sync_twist_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft threads are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft threads
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: track sync state for twists that created thread OR are mentioned
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft threads are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Track sync for twists that created thread OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.thread_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Track sync for twists that created thread OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.thread_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: track sync state for twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
            JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for note creator
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft threads
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
    -- Exit early if all changes were to tags on draft notes or draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected notes
    -- Only consider tags on non-draft notes on non-draft threads
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this note
        AND nt.created_by = pct.id
    ORDER BY
        pct.id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent thread's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent note's thread's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "find_matching_threads_scored" function
CREATE FUNCTION "public"."find_matching_threads_scored" ("query_embedding" text, "created_by_id" uuid, "required_filters" jsonb DEFAULT '{}', "scored_fields" jsonb DEFAULT '{}', "thread_data" jsonb DEFAULT '{}', "similarity_threshold" double precision DEFAULT 0.7) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "total_score" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY WITH filtered_threads AS (
        -- First filter by required exact matches
        SELECT
            a.id,
            a.priority_id,
            a.title,
            a.type,
            a.meta,
            a.embedding
        FROM
            public.thread a
        WHERE
            a.created_by = created_by_id
            AND a.archived_at IS NULL
            -- Content similarity filter (when content is required)
            -- Skip if query_embedding is null/empty (embedding generation failed)
            AND ((required_filters ? 'content'
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]'
                    AND a.embedding IS NOT NULL
                    AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND a.type = (thread_data ->> 'type')::thread_type)
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (a.meta IS NULL
                            OR a.meta ->> substring(key FROM 6) IS DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6))))
),
scored_threads AS (
    -- Calculate scores for each matching thread
    SELECT
        fa.id,
        fa.priority_id,
        fa.title,
        -- Sum up all scores
        (
            -- Content similarity score (skip if query_embedding is null/empty)
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fa.embedding IS NOT NULL
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]' THEN
                    (scored_fields ->> 'content')::float * (1 - (fa.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fa.type = (thread_data ->> 'type')::thread_type THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                    END
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fa.meta IS NOT NULL
                                AND fa.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_threads fa
)
SELECT
    sa.id,
    sa.priority_id,
    sa.title,
    sa.total_score
FROM
    scored_threads sa
WHERE
    sa.total_score > 0
ORDER BY
    sa.total_score DESC
LIMIT 1;
END;
$$;
-- Create "find_similar_threads" function
CREATE FUNCTION "public"."find_similar_threads" ("query_embedding" text, "created_by_id" uuid, "similarity_threshold" double precision DEFAULT 0.5, "match_limit" integer DEFAULT 1) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.priority_id,
        a.title,
        1 - (a.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.thread a
    WHERE
        a.created_by = created_by_id
        AND a.embedding IS NOT NULL
        AND a.archived_at IS NULL
        AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        a.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;
-- Create "get_thread_mentions" function
CREATE FUNCTION "public"."get_thread_mentions" ("p_thread_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM
        note n,
        LATERAL unnest(n.mentions) AS mention
    WHERE
        n.thread_id = p_thread_id
        AND n.archived_at IS NULL
        AND n.mentions IS NOT NULL;
$$;
-- Modify "update_note_tags" function
CREATE OR REPLACE FUNCTION "user"."update_note_tags" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    v_priority_id uuid;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Validate access to the note's thread priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Note not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Validate computed tags for notes
            -- Notes can have 'now' (1), 'done' (3), and 'someday' (7) tags for per-user assignment/completion
            -- But not 'later' (2), 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3, 7) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3, 7 (now, done, someday)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3, 7)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'now' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$$;
-- Modify "upsert_note_tag" function
CREATE OR REPLACE FUNCTION "user"."upsert_note_tag" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_tag_id" integer, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row note_tag;
BEGIN
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Note not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "delete_thread_read" function
CREATE FUNCTION "user"."delete_thread_read" ("user_id" uuid, "p_thread_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(delete_thread_read.user_id, v_priority_id);

    DELETE FROM thread_read
    WHERE
        thread_read.user_id = delete_thread_read.user_id
        AND thread_read.thread_id = p_thread_id;
END;
$$;
-- Create "delete_thread_user_state" function
CREATE FUNCTION "user"."delete_thread_user_state" ("user_id" uuid, "p_thread_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(delete_thread_user_state.user_id, v_priority_id);

    DELETE FROM thread_user_state
    WHERE
        thread_user_state.user_id = delete_thread_user_state.user_id
        AND thread_user_state.thread_id = p_thread_id;
END;
$$;
-- Create "mentioned_in_thread" function
CREATE FUNCTION "user"."mentioned_in_thread" ("user_id" uuid, "thread_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.thread_id = mentioned_in_thread.thread_id
                AND note.archived_at IS NULL
                AND mentioned_in_thread.user_id = ANY (note.mentions));
$$;
-- Create "update_thread_tags" function
CREATE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread's priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        thread a
    WHERE
        a.id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches current user's contact_id
                IF p_actor_id != "user".user_contact_id (user_id) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- RSVP tags (Attend/Skip/Undecided) are mutually exclusive
                -- If adding an RSVP tag, remove the other two for this actor
                IF is_rsvp_tag (tag_id_int) THEN
                    UPDATE
                        thread_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        thread_id = p_thread_id
                        AND actor_id = p_actor_id
                        AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                        AND tag_id IN (1019, 1020, 1021) -- All RSVP tags
                        AND tag_id != tag_id_int -- Except the one being added
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on threads
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id)
                SELECT
                    a.priority_id,
                    p_actor_id
                FROM
                    thread a
                WHERE
                    a.id = p_thread_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_private" boolean, "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, private, content, actions, mentions, re_note_id, source_created_at, key)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (thread_id, key)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, private, content, actions, mentions, re_note_id, source_created_at, key)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Create "priority_unread" view
CREATE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(GREATEST(COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE COALESCE(a.last_note_created_at, a.created_at)
        END)) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.thread a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at)
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
  GROUP BY upe.user_id, upe.priority_id;
-- Create "priority" view
CREATE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread"
) AS SELECT pu.user_id,
    p.id,
    p.created_at,
    GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = true AND p.id = root.id AS root,
    user_root.path OPERATOR(public.@>) p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
        CASE
            WHEN inherited_settings.path IS NOT NULL THEN inherited_settings.path
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            WHEN parent_inherited_settings.path IS NOT NULL THEN parent_inherited_settings.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(p.path) - 1, 1)::text::public.ltree
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    COALESCE(upu.unread, false) AS unread
   FROM public.priority_user pu
     JOIN public.priority root ON pu.priority_id = root.id
     JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
     JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     JOIN public.priority p ON root.path OPERATOR(public.@>) p.path
     LEFT JOIN public.priority parent_p ON public.nlevel(p.path) > 1 AND parent_p.path OPERATOR(public.=) public.subpath(p.path, 0, public.nlevel(p.path) - 1)
     LEFT JOIN public.priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id AND parent_p.id = parent_inherited_settings.priority_id
     LEFT JOIN public.priority_settings settings ON settings.user_id = pu.user_id AND p.id = settings.priority_id
     LEFT JOIN public.priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id AND p.id = inherited_settings.priority_id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
  WHERE pu.archived_at IS NULL;
-- Create "upsert_priority" function
CREATE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority";
    _old "user"."priority";
    v_row "user"."priority";
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_actual_path ltree;
    _actual_path ltree;
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
BEGIN
    -- Extract input fields from JSONB into the view's row type
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = _input.id) INTO _priority_exists;
    -- Look up existing row from view if it exists (replaces OLD trigger variable)
    IF _priority_exists THEN
        SELECT
            * INTO _old
        FROM
            "user".priority up
        WHERE
            up.user_id = upsert_priority.user_id
            AND up.id = _input.id;
    END IF;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since global_path is a computed column
    IF _priority_exists THEN
        _old_actual_path := _old.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = _input.id;
        END IF;
        IF nlevel (_input.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
            _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                global_path INTO _parent_actual_path
            FROM
                "user".priority
            WHERE
                user_id = upsert_priority.user_id
                AND path = _parent_visual_path
            LIMIT 1;
            IF _parent_actual_path IS NULL THEN
                RAISE EXCEPTION 'Parent priority not found'
                    USING HINT = 'parent_visual_path=' || _parent_visual_path::text;
            END IF;
            -- Compute what the new actual path would be
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            -- Root level priority (nlevel = 1)
            _actual_path := _input.path;
        END IF;
    END IF;
    -- Detect if this is a move (actual path changed on existing priority)
    _is_move := (_priority_exists
        AND _actual_path IS NOT NULL
        AND _old_actual_path IS DISTINCT FROM _actual_path);
    IF _is_move THEN
        -- Block moving root priorities
        IF _input.root THEN
            RAISE EXCEPTION 'Cannot move root priority'
                USING HINT = 'Root priorities define access boundaries and cannot be moved';
        END IF;
        -- Get user's personal root path (actual path)
        SELECT
            p.path INTO _user_personal_root_path
        FROM
            priority_user pu
            JOIN priority p ON pu.priority_id = p.id
        WHERE
            pu.user_id = upsert_priority.user_id
            AND pu.personal = TRUE
            AND pu.archived_at IS NULL
        LIMIT 1;
        -- Determine if old and new locations are under personal root
        _old_is_personal := (_user_personal_root_path @> _old_actual_path);
        _new_is_personal := (_user_personal_root_path @> _actual_path);
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- Check if move is within an aliased tree
        _within_aliased_tree := FALSE;
        _aliased_root_id := NULL;
        IF NOT _old_is_personal AND _new_is_personal THEN
            -- Find deepest ancestor where both old and new paths are under the aliased root
            SELECT
                ps.priority_id INTO _aliased_root_id
            FROM
                priority_settings ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.path IS NOT NULL
                AND _input.path <@ ps.path
                AND _old.path <@ ps.path
                AND ps.path != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel (ps.path) DESC
            LIMIT 1;
            IF _aliased_root_id IS NOT NULL THEN
                _within_aliased_tree := TRUE;
            END IF;
        END IF;
        -- Determine move type and execute appropriate action
        IF _old_is_personal AND _new_is_personal THEN
            -- Type 1a: Actual move within personal tree
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal AND NOT _new_is_personal THEN
            -- Type 1b: Actual move within/between shared trees
            -- Notify users who lose access if the priority moves to a different shared tree
            PERFORM
                notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal
                AND _within_aliased_tree THEN
                -- Type 3: Actual move within aliased tree (no displacement - same root)
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal THEN
                -- Type 4: Actual move from shared tree into personal tree
                -- (was Type 2: visual alias; now corrected to a real path move)
                PERFORM
                    notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
                _actual_path := NULL;
                -- Clear any existing visual alias now that priority is in the personal tree
                UPDATE
                    priority_settings
                SET
                    path = NULL
                WHERE
                    user_id = upsert_priority.user_id
                    AND priority_id = _input.id;
        ELSIF _old_is_personal
                AND NOT _new_is_personal THEN
                RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                USING HINT = 'Use Share dialog to share a personal priority';
        END IF;
    END IF;
    -- Translate visual path to actual path for new sub-priorities
    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (_input.path) > 1 THEN
        _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
        _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
        SELECT
            global_path INTO _parent_actual_path
        FROM
            "user".priority
        WHERE
            user_id = upsert_priority.user_id
            AND path = _parent_visual_path
        LIMIT 1;
        IF _parent_actual_path IS NOT NULL THEN
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            _actual_path := _input.path;
        END IF;
    ELSIF _is_move IS NOT TRUE THEN
        _actual_path := _input.path;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF _actual_path IS NOT NULL THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (_input.id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields
        UPDATE
            priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN
                _input.color
            ELSE
                priority.color
            END,
            updated_by = _input.updated_by
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Update priority_settings for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
            VALUES (upsert_priority.user_id, _priority_id, _input.path, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = _input.path,
                top_order = _input.top_order,
                "order" = _input.order,
                pomodoro = _input.pomodoro,
                color = _input.color;
    ELSIF NOT _is_move
            AND (_input."top_order" IS NOT NULL
                OR _input."order" IS NOT NULL
                OR _input."pomodoro" IS NOT NULL
                OR _input."color" IS NOT NULL) THEN
            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                VALUES (upsert_priority.user_id, _priority_id, NULL, _input.top_order, _input.order, _input.pomodoro, COALESCE(_input.color, _priority_default_color))
            ON CONFLICT (user_id, priority_id)
                DO UPDATE SET
                    top_order = _input.top_order,
                    "order" = _input.order,
                    pomodoro = _input.pomodoro,
                    color = _input.color;
    END IF;
    -- Return the updated row from the view
    SELECT
        * INTO v_row
    FROM
        "user".priority up
    WHERE
        up.user_id = upsert_priority.user_id
        AND up.id = _input.id;
    RETURN v_row;
END;
$$;
-- Create "upsert_thread" function
CREATE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_type thread_type;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_created_by_twist_id bigint;
    v_assignee_id uuid;
    v_author_id uuid;
    -- Array handling
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_source := p_thread ->> 'source';
    v_type := COALESCE((p_thread ->> 'type')::thread_type, (p_defaults ->> 'type')::thread_type, 'note'::thread_type);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);
    END IF;
    -- DERIVE source_priority_root from priority_id when source exists but root not provided
    IF p_thread ? 'source_priority_root' AND (p_thread ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_thread ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL
            AND v_priority_id IS NOT NULL THEN
            SELECT
                subpath (p.path, 0, 1) INTO v_source_priority_root
            FROM
                priority p
            WHERE
                p.id = v_priority_id;
    END IF;
    -- Resolve id from source if not provided (for twist-created threads)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            a.id INTO v_id
        FROM
            thread a
        WHERE
            a.source = v_source
            AND a.source_priority_root = v_source_priority_root;
    END IF;
    -- Generate id if still not resolved
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_thread.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- DERIVE created_by_twist_id from created_by (priority_twist_id)
    IF p_thread ? 'created_by_twist_id' AND (p_thread ->> 'created_by_twist_id') IS NOT NULL THEN
        v_created_by_twist_id := (p_thread ->> 'created_by_twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_created_by_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;
    -- DERIVE default assignee for actions when assignee_id key is absent from both p_thread and p_defaults
    -- If key exists in p_thread (even with null value), use that value
    -- If key exists in p_defaults (even with null value), use that value
    -- If key is absent from both AND type is action, derive from priority_twist owner
    IF p_thread ? 'assignee_id' THEN
        v_assignee_id := (p_thread ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSIF v_type = 'action'
            AND v_created_by IS NOT NULL THEN
            v_assignee_id := get_priority_twist_owner_contact (v_created_by);
    ELSE
        v_assignee_id := NULL;
    END IF;
    -- Handle recurrence_exdates array conversion from JSONB (p_thread takes precedence over p_defaults)
    IF p_thread ? 'recurrence_exdates' AND jsonb_typeof(p_thread -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_thread -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Handle add/remove exdates
    IF p_thread ? 'recurrence_exdates_add' AND jsonb_typeof(p_thread -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_thread -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_thread ? 'recurrence_exdates_remove' AND jsonb_typeof(p_thread -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_thread -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;
    -- Check if existing thread is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (thread.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = thread.priority_id
                    AND upe.user_id = upsert_thread.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        thread
    WHERE
        id = v_id;
    -- If no existing thread, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_thread
    INSERT INTO thread (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, actions, source, updated_by, sync_depth, embedding, pick_priority, private, draft, "order")
        VALUES (v_id, v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_thread ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_thread ->> 'on')::daterange, (p_defaults ->> 'on')::daterange), COALESCE((p_thread ->> 'duration')::interval, (p_defaults ->> 'duration')::interval), COALESCE((p_thread ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_thread ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'), v_recurrence_exdates, COALESCE(p_thread -> 'meta', p_defaults -> 'meta'), COALESCE(p_thread -> 'actions', p_defaults -> 'actions'), v_source, COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_thread ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_thread -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE((p_thread ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first()))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            at = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange, thread.at)
            ELSE
                CASE WHEN p_thread ? 'at' THEN
                    (p_thread ->> 'at')::tstzrange
                ELSE
                    thread.at
                END
            END,
            "on" = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'on')::daterange, (p_defaults ->> 'on')::daterange, thread."on")
            ELSE
                CASE WHEN p_thread ? 'on' THEN
                    (p_thread ->> 'on')::daterange
                ELSE
                    thread."on"
                END
            END,
            duration = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'duration')::interval, (p_defaults ->> 'duration')::interval, thread.duration)
            ELSE
                CASE WHEN p_thread ? 'duration' THEN
                    (p_thread ->> 'duration')::interval
                ELSE
                    thread.duration
                END
            END,
            done_at = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz, thread.done_at)
            ELSE
                CASE WHEN p_thread ? 'done_at' THEN
                    (p_thread ->> 'done_at')::timestamptz
                ELSE
                    thread.done_at
                END
            END,
            recurrence_rule = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule', thread.recurrence_rule)
            ELSE
                CASE WHEN p_thread ? 'recurrence_rule' THEN
                    p_thread ->> 'recurrence_rule'
                ELSE
                    thread.recurrence_rule
                END
            END,
            recurrence_exdates = CASE WHEN v_is_archived THEN
                -- v_recurrence_exdates already has p_thread fallback to p_defaults
                COALESCE(v_recurrence_exdates, thread.recurrence_exdates)
            WHEN p_thread ? 'recurrence_exdates' THEN
                -- Full replace
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                -- Incremental add/remove
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(thread.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                thread.recurrence_exdates
            END,
            meta = CASE WHEN v_is_archived THEN
                COALESCE(p_thread -> 'meta', p_defaults -> 'meta', thread.meta)
            ELSE
                CASE WHEN p_thread ? 'meta' THEN
                    p_thread -> 'meta'
                ELSE
                    thread.meta
                END
            END,
            actions = CASE WHEN v_is_archived THEN
                COALESCE(p_thread -> 'actions', p_defaults -> 'actions', thread.actions)
            ELSE
                CASE WHEN p_thread ? 'actions' THEN
                    p_thread -> 'actions'
                ELSE
                    thread.actions
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            type = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'type')::thread_type, (p_defaults ->> 'type')::thread_type, thread.type)
            ELSE
                CASE WHEN p_thread ? 'type' THEN
                    (p_thread ->> 'type')::thread_type
                ELSE
                    thread.type
                END
            END,
            assignee_id = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_assignee_id, thread.assignee_id)
            ELSE
                CASE WHEN p_thread ? 'assignee_id' THEN
                    (p_thread ->> 'assignee_id')::uuid
                ELSE
                    COALESCE(v_assignee_id, thread.assignee_id)
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, thread.private)
            ELSE
                CASE WHEN p_thread ? 'private' THEN
                    (p_thread ->> 'private')::boolean
                ELSE
                    thread.private
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            source = COALESCE(v_source, thread.source),
            source_priority_root = COALESCE(v_source_priority_root, thread.source_priority_root),
            created_by = v_created_by,
            created_by_twist_id = v_created_by_twist_id,
            "order" = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, thread."order")
            ELSE
                CASE WHEN p_thread ? 'order' THEN
                    (p_thread ->> 'order')::double precision
                ELSE
                    thread."order"
                END
            END
        RETURNING
            * INTO v_result;
    -- Handle per-user thread state (user_on, user_order)
    -- Key present with non-null value: upsert into thread_user_state
    -- Key present with null value: delete from thread_user_state (remove from Now+Next)
    -- Key absent: don't touch thread_user_state
    IF p_thread ? 'user_on' THEN
        IF (p_thread ->> 'user_on') IS NOT NULL THEN
            INSERT INTO thread_user_state (user_id, thread_id, "on", "order")
                VALUES (
                    upsert_thread.user_id,
                    v_result.id,
                    (p_thread ->> 'user_on')::daterange,
                    COALESCE((p_thread ->> 'user_order')::double precision, public.order_first())
                )
            ON CONFLICT (user_id, thread_id)
                DO UPDATE SET
                    "on" = EXCLUDED."on",
                    "order" = COALESCE(
                        CASE WHEN p_thread ? 'user_order' THEN (p_thread ->> 'user_order')::double precision END,
                        thread_user_state."order"
                    ),
                    updated_at = now();
        ELSE
            DELETE FROM thread_user_state
            WHERE thread_user_state.user_id = upsert_thread.user_id
                AND thread_user_state.thread_id = v_result.id;
        END IF;
    ELSIF p_thread ? 'user_order' AND (p_thread ->> 'user_order') IS NOT NULL THEN
        -- Order-only update (no on change) — only update if row exists
        UPDATE thread_user_state
        SET "order" = (p_thread ->> 'user_order')::double precision,
            updated_at = now()
        WHERE thread_user_state.user_id = upsert_thread.user_id
            AND thread_user_state.thread_id = v_result.id;
    END IF;
    RETURN v_result;
END;
$$;
-- Create "upsert_thread_exception" function
CREATE FUNCTION "user"."upsert_thread_exception" ("user_id" uuid, "p_id" uuid, "p_thread_id" uuid, "p_occurrence" text, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_updated_by" integer DEFAULT 0, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_on" daterange DEFAULT NULL::daterange, "p_duration" interval DEFAULT NULL::interval, "p_done_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_title" text DEFAULT NULL::text, "p_preview" text DEFAULT NULL::text, "p_meta" jsonb DEFAULT NULL::jsonb) RETURNS "public"."thread_exception" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_row thread_exception;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    INSERT INTO thread_exception (id, thread_id, occurrence, archived_at, updated_by, at, "on", duration, done_at, title, preview, meta)
        VALUES (COALESCE(p_id, uuidv7()), p_thread_id, p_occurrence, p_archived_at, COALESCE(p_updated_by, 0), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_meta)
    ON CONFLICT (thread_id, occurrence)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            at = EXCLUDED.at,
            "on" = EXCLUDED."on",
            duration = EXCLUDED.duration,
            done_at = EXCLUDED.done_at,
            title = EXCLUDED.title,
            preview = EXCLUDED.preview,
            meta = EXCLUDED.meta,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_thread_read" function
CREATE FUNCTION "user"."upsert_thread_read" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz) RETURNS "public"."thread_read" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_read;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(upsert_thread_read.user_id, v_priority_id);

    INSERT INTO thread_read (user_id, thread_id, read_at)
        VALUES (upsert_thread_read.user_id, p_thread_id, COALESCE(p_read_at, now()))
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = EXCLUDED.read_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_thread_tag" function
CREATE FUNCTION "user"."upsert_thread_tag" ("user_id" uuid, "p_actor_id" uuid, "p_thread_id" uuid, "p_tag_id" integer, "p_occurrence" text DEFAULT NULL::text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_tag" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row thread_tag;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_thread_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_thread_user_state" function
CREATE FUNCTION "user"."upsert_thread_user_state" ("user_id" uuid, "p_thread_id" uuid, "p_on" daterange, "p_order" double precision) RETURNS "public"."thread_user_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_user_state;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(upsert_thread_user_state.user_id, v_priority_id);

    INSERT INTO thread_user_state (user_id, thread_id, "on", "order")
        VALUES (upsert_thread_user_state.user_id, p_thread_id, p_on, p_order)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            "on" = EXCLUDED."on",
            "order" = EXCLUDED."order",
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "note_tags" view
CREATE VIEW "public"."note_tags" (
  "note_id",
  "tags",
  "updated_at",
  "updated_by"
) AS SELECT note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT nt.note_id,
            nt.tag_id,
            jsonb_agg(nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
            max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
            (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
           FROM public.note_tag nt
          GROUP BY nt.note_id, nt.tag_id) sq
  GROUP BY note_id;
-- Create "priority_tags" view
CREATE VIEW "public"."priority_tags" (
  "priority_id",
  "tag_id",
  "count",
  "updated_at"
) AS SELECT a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
   FROM public.thread_tag at
     JOIN public.thread a ON at.thread_id = a.id
  WHERE at.archived_at IS NULL AND a.archived_at IS NULL
  GROUP BY a.priority_id, at.tag_id;
-- Create "priority_twist_note_create" view
CREATE VIEW "public"."priority_twist_note_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT base.priority_twist_id,
    base.id,
    base.created_at,
    base.updated_at,
    base.source_created_at,
    base.author_id,
    base.created_by,
    base.updated_by,
    base.sync_depth,
    base.archived_at,
    base.thread_id,
    base.draft,
    base.private,
    base.content,
    base.actions,
    base.key,
    base.mentions,
    base.re_note_id,
    base.priority_id,
    base.thread_title,
    base.thread_created_by,
    base.thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM ( SELECT pt.id AS priority_twist_id,
            n.id,
            n.created_at,
            n.updated_at,
            n.source_created_at,
            n.author_id,
            n.created_by,
            n.updated_by,
            n.sync_depth,
            n.archived_at,
            n.thread_id,
            n.draft,
            n.private,
            n.content,
            n.actions,
            n.key,
            n.mentions,
            n.re_note_id,
            a.priority_id,
            a.title AS thread_title,
            a.created_by AS thread_created_by,
            a.meta AS thread_meta
           FROM public.priority_twist pt
             JOIN public.priority pp ON pp.id = pt.priority_id
             JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
             JOIN public.thread a ON a.priority_id = pc.id AND a.created_by = pt.id AND a.archived_at IS NULL
             JOIN public.note n ON n.thread_id = a.id
          WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
        UNION ALL
         SELECT pt.id AS priority_twist_id,
            n.id,
            n.created_at,
            n.updated_at,
            n.source_created_at,
            n.author_id,
            n.created_by,
            n.updated_by,
            n.sync_depth,
            n.archived_at,
            n.thread_id,
            n.draft,
            n.private,
            n.content,
            n.actions,
            n.key,
            n.mentions,
            n.re_note_id,
            a.priority_id,
            a.title AS thread_title,
            a.created_by AS thread_created_by,
            a.meta AS thread_meta
           FROM public.priority_twist pt
             JOIN public.priority pp ON pp.id = pt.priority_id
             JOIN LATERAL ( SELECT m.thread_id,
                    min(m.created_at) AS first_mention_at
                   FROM public.note m
                  WHERE m.mentions @> ARRAY[pt.id] AND m.archived_at IS NULL
                  GROUP BY m.thread_id) fm ON true
             JOIN public.thread a ON a.id = fm.thread_id AND a.created_by <> pt.id AND a.archived_at IS NULL
             JOIN public.priority pc ON pc.id = a.priority_id AND pc.path OPERATOR(public.<@) pp.path
             JOIN public.note n ON n.thread_id = fm.thread_id AND n.created_at >= fm.first_mention_at
          WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at) base
     LEFT JOIN public.actor author ON author.id = base.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = base.id
  ORDER BY base.created_at;
-- Create "priority_twist_note_update" view
CREATE VIEW "public"."priority_twist_note_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    a.meta AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.note n ON a.id = n.thread_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Create "thread_tags" view
CREATE VIEW "public"."thread_tags" (
  "thread_id",
  "occurrence",
  "tags",
  "updated_at",
  "updated_by"
) AS SELECT thread_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT at.thread_id,
            at.occurrence,
            at.tag_id,
            jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
            max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
            (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
           FROM public.thread_tag at
          GROUP BY at.thread_id, at.occurrence, at.tag_id) sq
  GROUP BY thread_id, occurrence;
-- Create "priority_twist_thread_create" view
CREATE VIEW "public"."priority_twist_thread_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT pt.id AS priority_twist_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_thread_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id <> a.created_by AND a.archived_at IS NULL AND pt.archived_at IS NULL AND a.created_at > pt.created_at
  ORDER BY a.created_at;
-- Create "priority_twist_thread_tag_change" view
CREATE VIEW "public"."priority_twist_thread_tag_change" (
  "priority_twist_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS priority_twist_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.priority_child_twist pct ON pct.priority_child_id = a.priority_id AND pct.id = a.created_by
  WHERE a.draft = false;
-- Create "priority_twist_thread_update" view
CREATE VIEW "public"."priority_twist_thread_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_thread_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id = a.created_by AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "meta",
  "actions",
  "source",
  "created_by_twist_id",
  "embedding",
  "pick_priority",
  "last_note_created_at",
  "last_note_source_created_at",
  "source_priority_root",
  "priority_path",
  "mentions"
) AS SELECT a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.actions,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    public.get_thread_mentions(a.id) AS mentions
   FROM public.thread a
     JOIN public.priority p ON p.id = a.priority_id;
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "mentions",
  "re_note_id"
) AS SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (n.private = false OR n.created_by = upe.user_id OR (upe.user_id = ANY (n.mentions))) AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (a.draft = false OR a.created_by = upe.user_id) AND (n.private = true AND n.created_by <> upe.user_id AND NOT (upe.user_id = ANY (COALESCE(n.mentions, '{}'::uuid[]))) OR a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id));
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "assignee_id",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "meta",
  "actions",
  "source",
  "created_by_twist_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "range_at",
  "range_on",
  "unread",
  "user_on",
  "user_order"
) AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.actions,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
        CASE
            WHEN a.done_at IS NOT NULL THEN tstzrange(a.done_at, a.done_at, '[]'::text)
            WHEN aus."on" IS NOT NULL THEN NULL::tstzrange
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id OR a."on" IS NULL THEN
            CASE
                WHEN lower(a.at) >= GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) THEN a.at
                ELSE tstzrange(GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), '[]'::text)
            END
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN a.done_at IS NOT NULL THEN NULL::daterange
            WHEN aus."on" IS NOT NULL THEN aus."on"
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id THEN NULL::daterange
            WHEN a.at IS NOT NULL THEN NULL::daterange
            WHEN a."on" IS NOT NULL THEN a."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END
            ELSE false
        END, false) AS unread,
    aus."on" AS user_on,
    aus."order" AS user_order
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
     LEFT JOIN public.thread_user_state aus ON aus.user_id = upe.user_id AND aus.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::tstzrange AS at,
    NULL::daterange AS "on",
    NULL::interval AS duration,
    a.done_at,
    NULL::text AS recurrence_rule,
    NULL::timestamp with time zone[] AS recurrence_exdates,
    NULL::jsonb AS meta,
    NULL::jsonb AS actions,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    false AS unread,
    NULL::daterange AS user_on,
    NULL::double precision AS user_order
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_path",
  "range_at",
  "range_on",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR (ua.user_id = ANY (n.mentions)));
-- Create "thread_exception" view
CREATE VIEW "user"."thread_exception" (
  "user_id",
  "id",
  "thread_id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_path",
  "range_at",
  "range_on",
  "at",
  "on",
  "title",
  "preview"
) AS SELECT ua.user_id,
    ae.id,
    ae.thread_id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.preview
   FROM public.thread_exception ae
     JOIN "user".thread ua ON ua.id = ae.thread_id;
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_path",
  "range_at",
  "range_on",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
   FROM public.thread_tags at
     JOIN "user".thread ua ON ua.id = at.thread_id;
