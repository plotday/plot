-- Function to notify users who lose access to a priority when it is moved to a different tree.
-- For each user who had access via the old shared root but won't have access via the new root:
--   1. Archives (or creates) their priority_user entry for the moved priority
--   2. Updates user_sync so they receive a real-time push on next sync
--
-- Parameters:
--   p_priority_id    - The priority being moved
--   p_old_path       - The priority's current (old) actual path
--   p_new_parent_path - The new parent's actual path (NULL if moving to root)
--
-- Returns a table of displaced user IDs (for informational purposes; side effects always apply).
CREATE OR REPLACE FUNCTION public.notify_displaced_priority_users(
    p_priority_id uuid,
    p_old_path ltree,
    p_new_parent_path ltree
) RETURNS TABLE (displaced_user_id uuid)
LANGUAGE plpgsql SET search_path TO 'public' AS $function$
DECLARE
    v_priority_label text;
    v_new_path ltree;
    v_user_id uuid;
BEGIN
    -- Compute the new path for the priority after the move
    v_priority_label := ltree2text(subpath(p_old_path, -1));
    IF p_new_parent_path IS NULL THEN
        v_new_path := text2ltree(v_priority_label);
    ELSE
        v_new_path := text2ltree(ltree2text(p_new_parent_path) || '.' || v_priority_label);
    END IF;

    -- Find users who had access via the old root but not the new root
    FOR v_user_id IN
        WITH old_access AS (
            -- Users with a priority_user entry for the old tree's root priority
            SELECT DISTINCT pu.user_id
            FROM priority_user pu
            JOIN priority p ON p.id = pu.priority_id
            WHERE p.path = subltree(p_old_path, 0, 1)
              AND pu.archived_at IS NULL
        ),
        new_access AS (
            -- Users with a priority_user entry for the new tree's root priority
            SELECT DISTINCT pu.user_id
            FROM priority_user pu
            JOIN priority p ON p.id = pu.priority_id
            WHERE p.path = subltree(v_new_path, 0, 1)
              AND pu.archived_at IS NULL
        )
        SELECT oa.user_id
        FROM old_access oa
        LEFT JOIN new_access na ON na.user_id = oa.user_id
        WHERE na.user_id IS NULL  -- had old access, does not have new access
    LOOP
        -- Archive the priority_user entry to signal the client to delete local data
        INSERT INTO priority_user (user_id, priority_id, personal, archived_at)
            VALUES (v_user_id, p_priority_id, FALSE, now())
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET archived_at = now(), updated_at = now();

        -- Update user_sync so this user receives a real-time WebSocket push
        INSERT INTO user_sync (user_id, entity, last_update_at)
            VALUES (v_user_id, 'priority_user', now())
        ON CONFLICT (user_id, entity)
            DO UPDATE SET last_update_at = GREATEST(user_sync.last_update_at, EXCLUDED.last_update_at);

        RETURN NEXT;
    END LOOP;
END;
$function$;
