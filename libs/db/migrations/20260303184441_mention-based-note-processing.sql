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
    -- For creates: track sync state for twists that are mentioned in the note
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
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority_twist pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
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
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority_twist pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
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
-- Modify "priority_twist_note_create" view
CREATE OR REPLACE VIEW "public"."priority_twist_note_create" (
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
) AS SELECT pt.id AS priority_twist_id,
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
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id AND a.archived_at IS NULL
     JOIN public.note n ON n.thread_id = a.id AND (pt.id = ANY (n.mentions))
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
