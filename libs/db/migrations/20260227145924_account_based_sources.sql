-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
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

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority_twist pct ON n.created_by = pct.id
            WHERE
                n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
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

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority_twist pct ON n.created_by = pct.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
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

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
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
-- Modify "sync_twist_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
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

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN priority_twist pct ON a.created_by = pct.id
    WHERE
        a.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'thread', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "sync_user_for_source_channel" function
CREATE FUNCTION "public"."sync_user_for_source_channel" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Notify the owner of the source account
    FOR v_user_id IN SELECT DISTINCT
        pt.owner_id
    FROM
        new_table n
        JOIN priority_twist pt ON pt.id = n.priority_twist_id
    ORDER BY
        pt.owner_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'source_channel', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "source_channel" table
CREATE TABLE "public"."source_channel" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "priority_twist_id" uuid NOT NULL,
  "channel_id" text NOT NULL,
  "title" text NOT NULL,
  "priority_id" uuid NULL,
  "enabled" boolean NOT NULL DEFAULT false,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "source_channel_priority_twist_id_channel_id_key" UNIQUE ("priority_twist_id", "channel_id"),
  CONSTRAINT "source_channel_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE SET NULL,
  CONSTRAINT "source_channel_priority_twist_id_fkey" FOREIGN KEY ("priority_twist_id") REFERENCES "public"."priority_twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_source_channel_priority_id" to table: "source_channel"
CREATE INDEX "idx_source_channel_priority_id" ON "public"."source_channel" ("priority_id");
-- Create index "idx_source_channel_priority_twist_id" to table: "source_channel"
CREATE INDEX "idx_source_channel_priority_twist_id" ON "public"."source_channel" ("priority_twist_id");
-- Set comment to table: "source_channel"
COMMENT ON TABLE "public"."source_channel" IS 'Maps source channels (calendars, projects, etc.) to priorities. Each row represents a channel from an external provider that can be enabled and routed to a specific priority.';
-- Set comment to column: "channel_id" on table: "source_channel"
COMMENT ON COLUMN "public"."source_channel"."channel_id" IS 'Provider-specific global ID for the channel. The same calendar/project has the same ID across users.';
-- Set comment to column: "priority_id" on table: "source_channel"
COMMENT ON COLUMN "public"."source_channel"."priority_id" IS 'The priority this channel syncs data to. NULL means the channel is known but not routed to any priority.';
-- Create trigger "user_sync_source_channel_insert"
CREATE TRIGGER "user_sync_source_channel_insert" AFTER INSERT ON "public"."source_channel" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_source_channel"();
-- Create trigger "set_source_channel_created_at"
CREATE TRIGGER "set_source_channel_created_at" BEFORE INSERT ON "public"."source_channel" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_source_channel_updated_at"
CREATE TRIGGER "set_source_channel_updated_at" BEFORE INSERT OR UPDATE ON "public"."source_channel" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_source_channel_update"
CREATE TRIGGER "user_sync_source_channel_update" AFTER UPDATE ON "public"."source_channel" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_source_channel"();
-- Modify "sync_twist_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table;
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n;
    END IF;
    -- Exit early if nothing to sync
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts)
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'create', v_create_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    -- Process UPDATE operations
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
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

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN thread a ON a.id = n.thread_id
                JOIN priority_twist pct ON a.created_by = pct.id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
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

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN thread a ON a.id = n.thread_id
                JOIN priority_twist pct ON a.created_by = pct.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
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

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_twist pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
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
-- Modify "sync_user_for_priority_twist" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_priority_twist" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL

    UNION

    -- Source accounts (NULL priority_id): notify the owner directly
    SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    WHERE
        n.priority_id IS NULL

    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_twist', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist" table
ALTER TABLE "public"."twist" ADD COLUMN "logo_url" text NULL;
-- Drop "link" view
DROP VIEW "user"."link";
-- Drop "link_x" view
DROP VIEW "public"."link_x";
-- Modify "link" table
ALTER TABLE "public"."link" ADD COLUMN "channel_id" text NULL;
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

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN priority_twist pct ON nt.created_by = pct.id
    WHERE
        nt.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "upsert_priority_twist" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority_twist" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."priority_twist" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row priority_twist;
BEGIN
    -- Source accounts have NULL priority_id; skip access check for those
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);
    END IF;
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    INSERT INTO priority_twist (id, priority_id, twist_id, owner_id, name, config, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_priority_id, p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            config = EXCLUDED.config,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "priority_id",
  "twist_id",
  "twist_environment",
  "is_source",
  "owner_id",
  "name",
  "config",
  "logo_url",
  "link_types"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types
   FROM public.priority_twist pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;
-- Create "source_channel" view
CREATE VIEW "user"."source_channel" (
  "user_id",
  "id",
  "priority_twist_id",
  "channel_id",
  "title",
  "priority_id",
  "enabled",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.priority_twist_id,
    sc.channel_id,
    sc.title,
    sc.priority_id,
    sc.enabled,
    sc.created_at,
    sc.updated_at
   FROM public.source_channel sc
     JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id;
-- Create "link_x" view
CREATE VIEW "public"."link_x" (
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "source_priority_root",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "embedding",
  "match",
  "priority_id",
  "priority_path"
) AS SELECT l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.embedding,
    l.match,
    t.priority_id,
    p.path AS priority_path
   FROM public.link l
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.priority p ON p.id = t.priority_id;
-- Create "link" view
CREATE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "priority_id",
  "priority_path"
) AS SELECT upe.user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.priority_id,
    l.priority_path
   FROM public.link_x l
     JOIN "user".priority_expanded upe ON l.priority_id = upe.priority_id;
