-- Drop all views that reference twist_instance.priority_id before dropping the column.
-- Atlas recreates them later in this migration from the updated schema files.
DROP VIEW IF EXISTS "public"."twist_instance_thread_tag_change";
DROP VIEW IF EXISTS "public"."twist_instance_channel_note_create";
DROP VIEW IF EXISTS "public"."twist_instance_schedule_contact";
DROP VIEW IF EXISTS "public"."twist_instance_thread_schedule";
DROP VIEW IF EXISTS "public"."twist_instance_channel_link_update";
DROP VIEW IF EXISTS "public"."twist_instance_channel_link_create";
DROP VIEW IF EXISTS "public"."twist_instance_note_update";
DROP VIEW IF EXISTS "public"."twist_instance_note_create";
DROP VIEW IF EXISTS "public"."twist_instance_link_update";
DROP VIEW IF EXISTS "public"."twist_instance_thread_update";
DROP VIEW IF EXISTS "public"."twist_instance_thread_read";
DROP VIEW IF EXISTS "public"."priority_child_twist";
DROP VIEW IF EXISTS "user"."actor";
DROP VIEW IF EXISTS "user"."priority_actor";
DROP VIEW IF EXISTS "user"."twist";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" DROP COLUMN "priority_id", ADD COLUMN "draft" boolean NOT NULL DEFAULT false;
-- Create index "idx_twist_instance_owner_id" to table: "twist_instance"
CREATE INDEX "idx_twist_instance_owner_id" ON "public"."twist_instance" ("owner_id");
-- Modify "sync_twist_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
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
    -- Process CREATE operations: track sync for the twist that created this link
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'link', 'create', v_create_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    -- Process UPDATE operations
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'link', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_twist_instance_id uuid;
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
            AND a.draft = FALSE
            AND (n.content IS DISTINCT FROM o.content
                OR n.author_id IS DISTINCT FROM o.author_id
                OR n.source_created_at IS DISTINCT FROM o.source_created_at
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.re_note_id IS DISTINCT FROM o.re_note_id
                OR n.mentions IS DISTINCT FROM o.mentions
                OR n.actions IS DISTINCT FROM o.actions
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft threads
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations: track sync state for twists mentioned in the note.
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft)
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations: track sync state for twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft threads.
    IF TG_OP = 'UPDATE' THEN
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE
            AND (n.archived_at IS DISTINCT FROM o.archived_at
                OR n.tag_id IS DISTINCT FROM o.tag_id
                OR n.actor_id IS DISTINCT FROM o.actor_id);
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to tags on draft notes or draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected notes
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN twist_instance pct ON pct.id = nt.created_by
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                VALUES (v_twist_instance_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
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
        -- Only consider rows where meaningful fields actually changed, to avoid
        -- unnecessary twist_instance_sync updates from no-op upserts (which cause
        -- SyncRecovery to re-trigger connectors in a feedback loop).
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND (n.title IS DISTINCT FROM o.title
                OR n.preview IS DISTINCT FROM o.preview
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access IS DISTINCT FROM o.access
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.icon IS DISTINCT FROM o.icon
                OR n.priority_id IS DISTINCT FROM o.priority_id
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft threads (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Twists are workspace-level; match strictly by created_by.
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = n.created_by
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): reference old_table for draft true→false check
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = n.created_by
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published threads)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON pct.id = n.created_by
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'thread', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_twist_instance_id uuid;
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
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN twist_instance pct ON pct.id = a.created_by
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                VALUES (v_twist_instance_id, 'thread', 'update', v_max_updated_at)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "upsert_twist_instance" function
CREATE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row twist_instance;
BEGIN
    -- Twist instances are workspace-level (per-user); the caller can only
    -- manage their own instances.
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    INSERT INTO twist_instance (id, twist_id, owner_id, name, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            options = EXCLUDED.options,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "priority_child_twist" view
CREATE VIEW "public"."priority_child_twist" (
  "id",
  "twist_id",
  "owner_id",
  "name",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url"
) AS SELECT pt.id,
    pt.twist_id,
    pt.owner_id,
    pt.name,
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
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
     JOIN public.priority_child_twist pct ON pct.id = a.created_by
  WHERE a.draft = false;
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "twist_id",
  "twist_environment",
  "is_source",
  "shared",
  "key_option",
  "owner_id",
  "name",
  "options",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected"
) AS SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = pt.owner_id))
        END AS user_connected
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id;
-- Modify "twist_instance_channel_link_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_link_create" (
  "twist_instance_id",
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
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
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
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.priority pc ON pc.id = t.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Modify "twist_instance_channel_link_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_link_update" (
  "twist_instance_id",
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
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
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
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.priority pc ON pc.id = t.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.twist_instance_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Modify "twist_instance_channel_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
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
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "link_id",
  "link_source",
  "link_title",
  "link_type",
  "link_meta",
  "link_channel_id",
  "link_source_url",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "author_name",
  "author_type",
  "tags"
) AS SELECT DISTINCT ON (ptc.twist_instance_id, n.id) ptc.twist_instance_id,
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
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    t.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;
-- Modify "twist_instance_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
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
  "access_contacts",
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
) AS SELECT pt.id AS twist_instance_id,
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
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
-- Modify "twist_instance_thread_read" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Modify "twist_instance_thread_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.priority pc ON pc.id = a.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Modify "priority_actor" view
CREATE OR REPLACE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "depth",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    depth,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT ancestor_contacts.user_id,
            ancestor_contacts.priority_path,
            ancestor_contacts.actor_id,
            ancestor_contacts.depth,
            ancestor_contacts.created_at,
            ancestor_contacts.updated_at,
            ancestor_contacts.archived_at
           FROM ( SELECT DISTINCT ON (upe.user_id, upe.path, pc.contact_id) upe.user_id,
                    upe.path AS priority_path,
                    pc.contact_id AS actor_id,
                    public.nlevel(p.path) - public.nlevel(ancestor.path) AS depth,
                    LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
                    GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                        CASE
                            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                            ELSE c.archived_at
                        END AS archived_at
                   FROM "user".priority_expanded upe
                     JOIN public.priority p ON p.id = upe.priority_id
                     JOIN public.priority ancestor ON p.path OPERATOR(public.<@) ancestor.path AND ancestor.user_id = p.user_id
                     JOIN public.priority_contact pc ON pc.priority_id = ancestor.id
                     JOIN public.contact c ON c.id = pc.contact_id
                  WHERE c.user_id IS NULL OR c."primary" = true
                  ORDER BY upe.user_id, upe.path, pc.contact_id, (public.nlevel(ancestor.path)) DESC) ancestor_contacts
        UNION ALL
         SELECT p.user_id,
            p.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM public.priority p
             JOIN public.twist_instance pt ON pt.owner_id = p.user_id
          WHERE p.archived_at IS NULL) actors;
-- Modify "twist_instance_link_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_link_update" (
  "twist_instance_id",
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
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT l.created_by AS twist_instance_id,
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
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread t ON t.id = l.thread_id
     LEFT JOIN public.priority pc ON pc.id = t.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(pt.id) <> l.updated_by::numeric AND pt.archived_at IS NULL AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Modify "twist_instance_note_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
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
  "access_contacts",
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
) AS SELECT n.created_by AS twist_instance_id,
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
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON n.created_by = pt.id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Modify "twist_instance_schedule_contact" view
CREATE OR REPLACE VIEW "public"."twist_instance_schedule_contact" (
  "twist_instance_id",
  "schedule_contact_id",
  "schedule_id",
  "contact_id",
  "status",
  "role",
  "archived_at",
  "thread_id",
  "link_id",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    s.thread_id,
    s.link_id,
    sc.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread a ON a.id = l.thread_id
     JOIN public.schedule s ON s.link_id = l.id
     JOIN public.schedule_contact sc ON sc.schedule_id = s.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
-- Modify "twist_instance_thread_schedule" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.archived_at IS NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
-- Drop "upsert_twist_instance" function
DROP FUNCTION "user"."upsert_twist_instance" (uuid, uuid, uuid, bigint, uuid, text, jsonb, timestamptz);
-- Recreate "user.actor" view (dropped at the top because priority_actor depended on it).
CREATE OR REPLACE VIEW "user"."actor" AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(MIN(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), MAX(upa.archived_at)) AS updated_at,
        CASE WHEN COUNT(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN
            MAX(upa.archived_at)
        ELSE
            NULL
        END AS archived_at,
        MIN(upa.depth) FILTER (WHERE upa.archived_at IS NULL) AS min_depth
    FROM "user".priority_actor upa
    GROUP BY upa.user_id, upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    ua.min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    EXISTS (
        SELECT 1 FROM contact c
        WHERE c.id = a.id AND c.user_id = ua.user_id
    ) AS self
FROM upa_agg ua
JOIN actor a ON a.id = ua.actor_id
UNION ALL
SELECT
    ua_primary.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    NULL::integer AS min_depth,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (c.user_id = ua_primary.user_id) AS self
FROM contact c
JOIN actor a ON a.id = c.id
JOIN contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
JOIN upa_agg ua_primary ON ua_primary.actor_id = c_primary.id
WHERE c."primary" = false;
