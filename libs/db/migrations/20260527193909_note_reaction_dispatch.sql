-- Create "sync_twist_for_note_reaction" function
CREATE FUNCTION "public"."sync_twist_for_note_reaction" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
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
        public.twist_instance_for_actor (nr.actor_id, nt.created_by)
    FROM
        new_table nr
        JOIN note nt ON nt.id = nr.note_id
        JOIN thread a ON a.id = nt.thread_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND public.twist_instance_for_actor (nr.actor_id, nt.created_by) IS NOT NULL
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
-- Create trigger "twist_sync_note_reaction_insert"
CREATE TRIGGER "twist_sync_note_reaction_insert" AFTER INSERT ON "public"."note_reaction" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note_reaction"();
-- Create trigger "twist_sync_note_reaction_update"
CREATE TRIGGER "twist_sync_note_reaction_update" AFTER UPDATE ON "public"."note_reaction" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note_reaction"();
-- Create "twist_instance_note_reaction_change" view
CREATE VIEW "public"."twist_instance_note_reaction_change" (
  "twist_instance_id",
  "id",
  "note_id",
  "thread_id",
  "actor_id",
  "emoji",
  "archived_at",
  "updated_at",
  "seq",
  "change_type"
) AS SELECT pt.id AS twist_instance_id,
    nr.id,
    nr.note_id,
    n.thread_id,
    nr.actor_id,
    nr.emoji,
    nr.archived_at,
    nr.updated_at,
    nr.seq,
        CASE
            WHEN nr.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.note_reaction nr
     JOIN public.note n ON n.id = nr.note_id
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.twist_instance pt ON pt.id = public.twist_instance_for_actor(nr.actor_id, n.created_by)
  WHERE n.draft = false AND a.draft = false AND nr.updated_at > pt.created_at;
