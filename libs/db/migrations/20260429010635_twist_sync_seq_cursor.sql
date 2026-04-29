-- Modify "twist_instance_sync" table
ALTER TABLE "public"."twist_instance_sync" ADD COLUMN "last_update_seq" xid8 NOT NULL DEFAULT '0'::xid8, ADD COLUMN "last_sync_seq" xid8 NOT NULL DEFAULT '0'::xid8;
-- Create index "idx_twist_instance_sync_pending_seq" to table: "twist_instance_sync"
CREATE INDEX "idx_twist_instance_sync_pending_seq" ON "public"."twist_instance_sync" ("twist_instance_id") WHERE (last_update_seq > last_sync_seq);
-- Modify "get_stale_twist_syncs" function
CREATE OR REPLACE FUNCTION "public"."get_stale_twist_syncs" ("p_stale_threshold" timestamptz, "p_limit" integer DEFAULT 50) RETURNS TABLE ("twist_instance_id" uuid) LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT DISTINCT
        pts.twist_instance_id
    FROM
        twist_instance_sync pts
        JOIN twist_instance pt ON pt.id = pts.twist_instance_id
    WHERE
        (pts.last_update_at > pts.last_sync_at OR pts.last_update_seq > pts.last_sync_seq)
        AND pts.last_sync_at < p_stale_threshold
        AND pt.archived_at IS NULL
    ORDER BY
        pts.twist_instance_id
    LIMIT p_limit;
$$;
-- Modify "get_stale_user_syncs" function
CREATE OR REPLACE FUNCTION "public"."get_stale_user_syncs" ("p_stale_threshold" timestamptz, "p_limit" integer DEFAULT 50) RETURNS TABLE ("user_id" uuid) LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT DISTINCT
        us.user_id
    FROM
        user_sync us
    WHERE
        (us.last_update_at > us.last_sync_at OR us.last_update_seq > us.last_sync_seq)
        AND us.last_sync_at < p_stale_threshold
    ORDER BY
        us.user_id
    LIMIT p_limit;
$$;
-- Modify "sync_twist_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at), MAX(seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table;
    ELSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
        FROM
            new_table n;
    END IF;
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'link', 'create', v_create_timestamp, v_create_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'link', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
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
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(n.created_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
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
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        ELSE
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        END IF;
    END IF;
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'note', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
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
            MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
        FROM
            new_table n
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
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
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                VALUES (v_twist_instance_id, 'note', 'update', v_max_updated_at, v_max_seq)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_create_seq xid8;
    v_update_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at), MAX(seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- Published rows: draft TRUE -> FALSE
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_create_timestamp, v_create_seq
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updates to already-published rows
        SELECT
            MAX(n.updated_at), MAX(n.seq) INTO v_update_timestamp, v_update_seq
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
                OR n.contacts IS DISTINCT FROM o.contacts
                OR n.icon IS DISTINCT FROM o.icon
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Mirror the sync_user_for_* fallback: empty batches / DELETEs leave seq
    -- NULL; clamp to the current xid so the cursor still advances monotonically.
    IF v_create_timestamp IS NOT NULL AND v_create_seq IS NULL THEN
        v_create_seq := pg_current_xact_id();
    END IF;
    IF v_update_timestamp IS NOT NULL AND v_update_seq IS NULL THEN
        v_update_seq := pg_current_xact_id();
    END IF;
    -- CREATE
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        ELSE
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
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp, v_create_seq)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                            last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
                END LOOP;
        END IF;
    END IF;
    -- UPDATE
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
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                    VALUES (v_twist_instance_id, 'thread', 'update', v_update_timestamp, v_update_seq)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                        last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    SELECT
        MAX(n.updated_at), MAX(n.seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        a.draft = FALSE;
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
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
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                VALUES (v_twist_instance_id, 'thread', 'update', v_max_updated_at, v_max_seq)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Drop "twist_instance_note_create" view
DROP VIEW "public"."twist_instance_note_create";
-- Create "twist_instance_note_create" view
CREATE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
    n.seq,
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
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
-- Drop "twist_instance_note_update" view
DROP VIEW "public"."twist_instance_note_update";
-- Create "twist_instance_note_update" view
CREATE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
    GREATEST(n.seq, COALESCE(nt.seq, '0'::xid8)) AS seq,
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
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON n.created_by = pt.id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Drop "twist_instance_thread_read" view
DROP VIEW "public"."twist_instance_thread_read";
-- Create "twist_instance_thread_read" view
CREATE VIEW "public"."twist_instance_thread_read" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    tu.seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Drop "twist_instance_thread_schedule" view
DROP VIEW "public"."twist_instance_thread_schedule";
-- Create "twist_instance_thread_schedule" view
CREATE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "archived_at",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.archived_at,
    s.updated_at,
    s.seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
-- Drop "twist_instance_thread_update" view
DROP VIEW "public"."twist_instance_thread_update";
-- Drop "thread_tags" view
DROP VIEW "public"."thread_tags";
-- Create "thread_tags" view
CREATE VIEW "public"."thread_tags" (
  "thread_id",
  "occurrence",
  "tags",
  "updated_at",
  "seq",
  "updated_by"
) AS SELECT thread_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    max(seq) AS seq,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT at.thread_id,
            at.occurrence,
            at.tag_id,
            jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
            max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
            max(at.seq) AS seq,
            (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
           FROM public.thread_tag at
          GROUP BY at.thread_id, at.occurrence, at.tag_id) sq
  GROUP BY thread_id, occurrence;
-- Create "twist_instance_thread_update" view
CREATE VIEW "public"."twist_instance_thread_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, COALESCE(at.seq, '0'::xid8)) AS seq,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Drop "twist_instance_channel_link_create" view
DROP VIEW "public"."twist_instance_channel_link_create";
-- Create "twist_instance_channel_link_create" view
CREATE VIEW "public"."twist_instance_channel_link_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
    l.seq,
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
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Drop "twist_instance_channel_link_update" view
DROP VIEW "public"."twist_instance_channel_link_update";
-- Create "twist_instance_channel_link_update" view
CREATE VIEW "public"."twist_instance_channel_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
    l.seq,
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
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.twist_instance_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Drop "twist_instance_schedule_contact" view
DROP VIEW "public"."twist_instance_schedule_contact";
-- Create "twist_instance_schedule_contact" view
CREATE VIEW "public"."twist_instance_schedule_contact" (
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
  "seq",
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
    sc.seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread a ON a.id = l.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.schedule s ON s.link_id = l.id
     JOIN public.schedule_contact sc ON sc.schedule_id = s.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "seq",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    at.seq,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.twist_instance_details tid ON tid.id = a.created_by
  WHERE a.draft = false;
-- Drop "twist_instance_channel_note_create" view
DROP VIEW "public"."twist_instance_channel_note_create";
-- Create "twist_instance_channel_note_create" view
CREATE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
    n.seq,
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
    tp.priority_id,
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
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;

-- Backfill: peg seq watermarks for existing rows to "now at migration time" so
-- the new seq cursor doesn't replay every row since each twist's creation on
-- first deploy. Connectors are idempotent, but unnecessary churn isn't free.
-- Any pre-migration in-flight callbacks fall back to the legacy timestamp
-- watermark (still written by triggers and read by SyncRecovery) until this
-- migration's transaction commits.
UPDATE twist_instance_sync
SET last_update_seq = pg_current_xact_id(),
    last_sync_seq = pg_current_xact_id();
