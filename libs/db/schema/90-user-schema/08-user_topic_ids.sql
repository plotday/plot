-- Topics the user is an EFFECTIVE stream member of: a direct contact member or
-- a member via an included group — minus per-user opt-outs.
-- Mirrors user.user_group_ids. Used by user.thread visibility and
-- user.user_has_thread_access.
--
-- NOTE: admins are a governance role, not auto-members of the stream; they
-- receive a topic's threads only if also a contact/group member. They still
-- see the topic entity via user.topic and can post via
-- user_has_thread_write_access.
CREATE OR REPLACE FUNCTION "user".user_topic_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT t.id), ARRAY[]::uuid[])
    FROM topic t
    WHERE t.archived_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = t.id AND o.user_id = p_user_id
      )
      AND (
          EXISTS (
              SELECT 1 FROM topic_contact tc
              JOIN user_contact uc ON uc.contact_id = tc.contact_id
                  AND uc.linked = TRUE AND uc.archived_at IS NULL
              WHERE tc.topic_id = t.id AND uc.user_id = p_user_id
          )
          OR EXISTS (
              SELECT 1 FROM topic_group tg
              JOIN group_member gm ON gm.group_id = tg.group_id
              JOIN user_contact uc ON uc.contact_id = gm.contact_id
                  AND uc.linked = TRUE AND uc.archived_at IS NULL
              WHERE tg.topic_id = t.id AND uc.user_id = p_user_id
          )
      );
$$;
