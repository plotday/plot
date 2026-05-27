-- Function to get tag type based on tag_id ranges.
-- After the toggle-tag retirement, the live ranges are:
--   1-99    → compute (system-managed indicators + the per-user writable
--             set: todo, done, twist)
--   1000+   → count   (per-user reactions; superseded by note_reaction
--             / thread_reaction tables but dispatch paths remain live
--             until the count-tag retirement follow-up lands)
-- The retired toggle range (100-999) raises — those rows were backfilled
-- into reactions and archived. The 'toggle' enum value is kept in the
-- tag_type type for backwards compatibility with old clients during the
-- rollout window; it will be dropped in a follow-up migration.
CREATE OR REPLACE FUNCTION get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id >= 1000 THEN
        RETURN 'count'::tag_type;
    END IF;
    RAISE EXCEPTION 'invalid tag_id: %', tag_id;
END;
$$;
