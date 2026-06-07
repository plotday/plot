-- Modify "sync_twist_for_note_reaction" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_reaction" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_twist_instance_id uuid;
BEGIN
    SELECT
        MAX(nr.updated_at), MAX(nr.seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table nr
        JOIN note nt ON nt.id = nr.note_id
        JOIN thread a ON a.id = nt.thread_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_twist_instance_id IN SELECT DISTINCT
        public.twist_instance_for_actor (nr.actor_id, COALESCE(nti.id, src.created_by))
    FROM
        new_table nr
        JOIN note nt ON nt.id = nr.note_id
        JOIN thread a ON a.id = nt.thread_id
        LEFT JOIN twist_instance nti ON nti.id = nt.created_by
        LEFT JOIN LATERAL (
            SELECT
                l.created_by
            FROM
                link l
                JOIN twist_instance lti ON lti.id = l.created_by
            WHERE
                l.thread_id = nt.thread_id
            ORDER BY
                l.created_at ASC
            LIMIT 1
        ) src ON TRUE
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND public.twist_instance_for_actor (nr.actor_id, COALESCE(nti.id, src.created_by)) IS NOT NULL
    ORDER BY
        1 LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at, last_update_seq)
                VALUES (v_twist_instance_id, 'note_reaction', 'update', v_max_updated_at, v_max_seq)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (twist_instance_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
