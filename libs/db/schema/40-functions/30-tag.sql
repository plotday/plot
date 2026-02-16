-- Function to get tag type based on tag_id ranges
-- This matches the hardcoded Tag enum in Flutter:
-- ids 1-99 are TagType.compute
-- ids 100-999 are TagType.toggle
-- ids 1000+ are TagType.count
CREATE OR REPLACE FUNCTION get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id BETWEEN 100 AND 999 THEN
        RETURN 'toggle'::tag_type;
    ELSE
        RETURN 'count'::tag_type;
    END IF;
END;
$$;

-- Function to check if a tag_id is an RSVP tag (Attend/Skip/Undecided)
-- RSVP tags are mutually exclusive - an actor can only have one at a time
CREATE OR REPLACE FUNCTION is_rsvp_tag (tag_id integer)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    -- RSVP tags: Attend (1019), Skip (1020), Undecided (1021)
    RETURN tag_id IN (1019, 1020, 1021);
END;
$$;


