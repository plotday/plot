-- Function to move a priority to a new parent, updating all descendant paths
CREATE OR REPLACE FUNCTION public.move_priority (p_priority_id uuid, p_new_parent_path ltree)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
    v_priority_team_id bigint;
    v_dest_parent_team_id bigint;
    v_new_parent_team_id bigint;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path,
        team_id INTO v_old_path,
        v_priority_team_id
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
    -- Block moves that cross team boundaries
    IF v_priority_team_id IS NOT NULL THEN
        IF p_new_parent_path IS NULL THEN
            RAISE EXCEPTION 'Cannot move team priority outside its team tree';
        END IF;
        SELECT
            team_id INTO v_dest_parent_team_id
        FROM
            public.priority
        WHERE
            path = p_new_parent_path;
        IF v_dest_parent_team_id IS DISTINCT FROM v_priority_team_id THEN
            RAISE EXCEPTION 'Cannot move team priority outside its team tree';
        END IF;
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
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
            text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
    -- Propagate team_id to moved priority and descendants (for moves into team tree)
    IF p_new_parent_path IS NOT NULL THEN
        SELECT
            team_id INTO v_new_parent_team_id
        FROM
            public.priority
        WHERE
            path = p_new_parent_path;
        IF v_new_parent_team_id IS NOT NULL THEN
            UPDATE
                public.priority
            SET
                team_id = v_new_parent_team_id
            WHERE
                path <@ v_new_path
                AND (team_id IS DISTINCT FROM v_new_parent_team_id);
        END IF;
    END IF;
END;
$function$;
