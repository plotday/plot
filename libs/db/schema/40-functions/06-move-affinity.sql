-- Deep-merge two move-affinity maps of shape
--   { "<source_focus_id>": { "<dest_focus_id>": <epoch_ms> } }
-- keeping the MAX epoch per (source, dest) cell. Used by
-- user.upsert_user_settings so two devices' concurrent offline moves both
-- survive (neither clobbers the other). Pure jsonb; no table dependencies, so
-- it lives in 40-functions (loaded before the user-schema upserts). PUBLIC
-- keeps default EXECUTE, matching the other helpers here.
CREATE OR REPLACE FUNCTION public.merge_move_affinity (existing jsonb, incoming jsonb)
    RETURNS jsonb
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT COALESCE(jsonb_object_agg(src, dests), '{}'::jsonb)
    FROM (
        SELECT s_key AS src, jsonb_object_agg(d_key, ms) AS dests
        FROM (
            SELECT s.key AS s_key, d.key AS d_key, max((d.value::text)::numeric) AS ms
            FROM (
                SELECT key, value FROM jsonb_each(COALESCE(existing, '{}'::jsonb))
                UNION ALL
                SELECT key, value FROM jsonb_each(COALESCE(incoming, '{}'::jsonb))
            ) s,
            LATERAL jsonb_each(s.value) d
            GROUP BY s.key, d.key
        ) cells
        GROUP BY s_key
    ) per_source;
$function$;
