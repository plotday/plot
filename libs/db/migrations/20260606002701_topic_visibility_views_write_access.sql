-- Modify "file_thread_priority_for_topic_members" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_for_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_author_user_id uuid;
BEGIN
    IF NEW.topic_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer_user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
    SET revoked_at = NULL
    WHERE thread_priority.revoked_at IS NOT NULL;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer_user_id, NEW.id
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Modify "user_has_thread_access" function
CREATE OR REPLACE FUNCTION "user"."user_has_thread_access" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
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
-- Modify "user_topic_ids" function
CREATE OR REPLACE FUNCTION "user"."user_topic_ids" ("p_user_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE AS $$
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
-- Modify "user_has_thread_write_access" function
CREATE OR REPLACE FUNCTION "user"."user_has_thread_write_access" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
WITH t AS (
        SELECT contacts, groups, topic_id FROM thread WHERE id = p_thread_id
    )
    SELECT EXISTS (
        SELECT 1
        FROM t
        WHERE t.contacts && "user".user_contact_ids(p_user_id)
    )
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN unnest(t.groups) AS g(id) ON TRUE
        JOIN "group" gr ON gr.id = g.id
        WHERE gr.type <> 'announce'
          AND g.id = ANY ("user".user_group_ids(p_user_id))
    )
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN unnest(t.groups) AS g(id) ON TRUE
        JOIN "group" gr ON gr.id = g.id
        JOIN group_admin ga ON ga.group_id = g.id
        WHERE gr.type = 'announce'
          AND ga.user_id = p_user_id
    )
    -- Topic path (non-announce): effective member of a non-announce topic.
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN topic tp ON tp.id = t.topic_id
        WHERE t.topic_id IS NOT NULL
          AND t.topic_id = ANY ("user".user_topic_ids(p_user_id))
          AND tp.announce = FALSE
    )
    -- Topic path (admin override): topic admins may post even to announce topics.
    OR EXISTS (
        SELECT 1
        FROM t
        JOIN topic_admin ta ON ta.topic_id = t.topic_id
        WHERE t.topic_id IS NOT NULL
          AND ta.user_id = p_user_id
    );
$$;
-- Modify "note" view
CREATE OR REPLACE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.access_groups,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.created_by = tp.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id))));
-- Modify "note_redacted" view
CREATE OR REPLACE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::uuid[] AS access_groups,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND n.created_by <> tp.user_id AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL) AND NOT (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND NOT (a.dropped_contacts IS NOT NULL AND cardinality(a.dropped_contacts) > 0 AND a.dropped_contacts && "user".user_contact_ids(tp.user_id));
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    true AS unread,
    max(ts.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (a.team_id IS NULL OR a.external_contacts && "user".user_contact_ids(tp.user_id) OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = a.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)))
     JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id AND ts.read_at IS NULL AND (ts.importance >= 50 OR ts.urgent = true)
  GROUP BY tp.user_id, ("user".effective_priority_id(tp.priority_id, tp.user_id));
