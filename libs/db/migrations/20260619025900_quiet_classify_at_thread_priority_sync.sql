-- Create "sync_user_for_thread_priority_update" function
CREATE FUNCTION "public"."sync_user_for_thread_priority_update" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Watermark over only the rows with a user-visible change.
    SELECT MAX(n.updated_at), MAX(n.seq)
      INTO v_max_updated_at, v_max_seq
      FROM new_table n
      JOIN old_table o ON o.thread_id = n.thread_id AND o.user_id = n.user_id
     WHERE to_jsonb(n) - 'classify_at' - 'seq' - 'updated_at'
           IS DISTINCT FROM to_jsonb(o) - 'classify_at' - 'seq' - 'updated_at';

    -- Nothing view-relevant changed in the whole statement (classify_at-only):
    -- stay quiet, leave the user_sync singleton untouched.
    IF v_max_seq IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_updated_at IS NULL THEN
        v_max_updated_at := now();
    END IF;

    -- Skip users that no longer exist (mirrors sync_user_for_thread_priority's
    -- CASCADE-delete guard).
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
        JOIN old_table o ON o.thread_id = n.thread_id AND o.user_id = n.user_id
    WHERE
        EXISTS (SELECT 1 FROM "user" u WHERE u.id = n.user_id)
        AND to_jsonb(n) - 'classify_at' - 'seq' - 'updated_at'
            IS DISTINCT FROM to_jsonb(o) - 'classify_at' - 'seq' - 'updated_at'
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "user_sync_thread_priority_update" trigger
CREATE OR REPLACE TRIGGER "user_sync_thread_priority_update" AFTER UPDATE ON "public"."thread_priority" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_thread_priority_update"();
