-- Create "sync_user_for_team_user" function
CREATE FUNCTION "public"."sync_user_for_team_user" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(seq) INTO v_max_seq
    FROM
        new_table;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify the affected user directly
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'team_user', now(), v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_team_user_insert"
CREATE TRIGGER "user_sync_team_user_insert" AFTER INSERT ON "public"."team_user" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_team_user"();
-- Create trigger "user_sync_team_user_update"
CREATE TRIGGER "user_sync_team_user_update" AFTER UPDATE ON "public"."team_user" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_team_user"();
-- Create "team_user" view
CREATE VIEW "user"."team_user" (
  "id",
  "user_id",
  "team_id",
  "role",
  "archived_at",
  "seq",
  "team_name"
) AS SELECT tu.id,
    tu.user_id,
    tu.team_id,
    tu.role,
    tu.archived_at,
    tu.seq,
    t.name AS team_name
   FROM public.team_user tu
     JOIN public.team t ON t.id = tu.team_id;
