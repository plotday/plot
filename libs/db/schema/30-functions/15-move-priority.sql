-- Function to move a priority to a new parent, updating all descendant paths
CREATE OR REPLACE FUNCTION move_priority (
    p_priority_id uuid,
    p_new_parent_path ltree
)
    RETURNS void
    AS $$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path INTO v_old_path
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, - 1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
            -- For the priority itself, use the new path directly
            WHEN path = v_old_path THEN
                v_new_path
            -- For descendants, replace the old path prefix with the new path
            ELSE
                text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
            END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
END;
$$
LANGUAGE plpgsql;

