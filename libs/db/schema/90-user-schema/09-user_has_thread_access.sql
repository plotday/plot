-- Does the user still have ANY visibility path to this thread?
--   direct contact · group on the thread · the thread's topic.
-- The single source of truth for revoke decisions across all triggers.
--
-- IMPORTANT — why plpgsql with INLINED table reads (not a thin sql wrapper
-- over user_group_ids/user_topic_ids): Atlas's migrate-diff parses function
-- *call* graphs (even through plpgsql) and the *table* references inside
-- LANGUAGE sql bodies. A membership-change trigger that (transitively) calls
-- user_group_ids/user_topic_ids — which read group_member/topic_contact —
-- makes the trigger appear to depend on its OWN table, an unorderable diff
-- cycle ("modify <table>: relation does not exist"). plpgsql bodies are opaque
-- to the table-dependency parser, so inlining the membership lookups here (and
-- calling no sql helper that reads those tables) keeps the helper usable from
-- triggers without creating the cycle.
CREATE OR REPLACE FUNCTION "user".user_has_thread_access (p_user_id uuid, p_thread_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    AS $$
DECLARE
    v_contacts uuid[];
    v_groups uuid[];
    v_topic_id uuid;
BEGIN
    SELECT contacts, groups, topic_id INTO v_contacts, v_groups, v_topic_id
    FROM thread WHERE id = p_thread_id;
    IF NOT FOUND THEN RETURN FALSE; END IF;

    -- direct contact path
    IF EXISTS (
        SELECT 1 FROM user_contact uc
        WHERE uc.user_id = p_user_id AND uc.linked = TRUE AND uc.archived_at IS NULL
          AND uc.contact_id = ANY(v_contacts)
    ) THEN RETURN TRUE; END IF;

    -- group-on-thread path
    IF EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE uc.user_id = p_user_id AND gm.group_id = ANY(v_groups)
    ) THEN RETURN TRUE; END IF;

    -- topic path: stream membership (direct contact / via group) minus opt-out.
    -- NOTE: admins are a governance role, not auto-members of the stream; they
    -- receive threads only if also a contact/group member. This mirrors
    -- user_topic_ids which also excludes the admin path.
    IF v_topic_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM topic tp
                   WHERE tp.id = v_topic_id AND tp.archived_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM topic_member_optout o
                       WHERE o.topic_id = v_topic_id AND o.user_id = p_user_id)
       AND (
           EXISTS (
               SELECT 1 FROM topic_contact tc
               JOIN user_contact uc ON uc.contact_id = tc.contact_id
                   AND uc.linked = TRUE AND uc.archived_at IS NULL
               WHERE tc.topic_id = v_topic_id AND uc.user_id = p_user_id
           )
           OR EXISTS (
               SELECT 1 FROM topic_group tg
               JOIN group_member gm ON gm.group_id = tg.group_id
               JOIN user_contact uc ON uc.contact_id = gm.contact_id
                   AND uc.linked = TRUE AND uc.archived_at IS NULL
               WHERE tg.topic_id = v_topic_id AND uc.user_id = p_user_id
           )
       )
    THEN RETURN TRUE; END IF;

    RETURN FALSE;
END;
$$;
