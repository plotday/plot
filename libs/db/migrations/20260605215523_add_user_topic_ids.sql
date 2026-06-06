-- Create "user_topic_ids" function
CREATE FUNCTION "user"."user_topic_ids" ("p_user_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
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
          OR EXISTS (
              SELECT 1 FROM topic_admin ta
              WHERE ta.topic_id = t.id AND ta.user_id = p_user_id
          )
      );
$$;
