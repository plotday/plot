-- Create "sync_user_for_role" function
CREATE FUNCTION "public"."sync_user_for_role" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- Empty-batch / NULL-seq fallback to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        n.user_id IS NOT NULL
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'role', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_role_insert"
CREATE TRIGGER "user_sync_role_insert" AFTER INSERT ON "public"."role" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_role"();
-- Create trigger "user_sync_role_update"
CREATE TRIGGER "user_sync_role_update" AFTER UPDATE ON "public"."role" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_role"();
