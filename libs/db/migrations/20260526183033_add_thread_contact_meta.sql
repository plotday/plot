-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop reaction views (defined out-of-tree in the local DB; recreated at end
-- of this migration so they pick up the new contact_meta column on user.thread)
DROP VIEW IF EXISTS "user"."thread_reactions";
DROP VIEW IF EXISTS "user"."note_reactions";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Drop "thread_redacted" view
DROP VIEW "user"."thread_redacted";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "contact_meta" jsonb NOT NULL DEFAULT '{}';
-- Create "share_thread" function
CREATE FUNCTION "public"."share_thread" ("p_user_id" uuid, "p_thread_id" uuid, "p_add_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_remove_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_contact_roles" jsonb DEFAULT '[]', "p_role_changes" jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_contacts uuid[];
    v_new_contacts uuid[];
    v_current_meta jsonb;
    v_new_meta jsonb;
    v_needs_invitation uuid[];
    r RECORD;
    v_role RECORD;
BEGIN
    -- Validate caller has access to this thread
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    -- Fetch current contacts and meta
    SELECT contacts, contact_meta INTO v_current_contacts, v_current_meta
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_contacts IS NULL THEN
        v_current_contacts := ARRAY[]::uuid[];
    END IF;
    IF v_current_meta IS NULL THEN
        v_current_meta := '{}'::jsonb;
    END IF;

    -- Compute new contacts: (current + add) - remove, deduplicated
    SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_new_contacts
    FROM (
        SELECT unnest(v_current_contacts) AS cid
        UNION
        SELECT unnest(p_add_contact_ids)
    ) all_contacts
    WHERE cid != ALL(COALESCE(p_remove_contact_ids, ARRAY[]::uuid[]));

    -- Compute new contact_meta:
    --   1. Drop entries for removed contacts.
    --   2. Apply p_contact_roles for added contacts.
    --   3. Apply p_role_changes for existing contacts.
    v_new_meta := v_current_meta;

    -- Strip removed contacts' meta entries
    IF array_length(p_remove_contact_ids, 1) > 0 THEN
        FOR v_role IN SELECT unnest(p_remove_contact_ids) AS cid LOOP
            v_new_meta := v_new_meta - (v_role.cid::text);
        END LOOP;
    END IF;

    -- Apply add-time role assignments
    FOR v_role IN
        SELECT
            (entry->>'contactId')::uuid AS contact_id,
            entry->>'role' AS role
        FROM jsonb_array_elements(COALESCE(p_contact_roles, '[]'::jsonb)) AS entry
        WHERE entry->>'contactId' IS NOT NULL AND entry->>'role' IS NOT NULL
    LOOP
        v_new_meta := v_new_meta || jsonb_build_object(
            v_role.contact_id::text,
            jsonb_build_object('role', v_role.role, 'addedBy', p_user_id::text)
        );
    END LOOP;

    -- Apply role changes on existing contacts. addedBy is preserved from
    -- the existing entry when present, otherwise falls back to caller.
    FOR v_role IN
        SELECT
            (entry->>'contactId')::uuid AS contact_id,
            entry->>'role' AS role
        FROM jsonb_array_elements(COALESCE(p_role_changes, '[]'::jsonb)) AS entry
        WHERE entry->>'contactId' IS NOT NULL AND entry->>'role' IS NOT NULL
    LOOP
        v_new_meta := v_new_meta || jsonb_build_object(
            v_role.contact_id::text,
            jsonb_build_object(
                'role', v_role.role,
                'addedBy', COALESCE(
                    v_new_meta->(v_role.contact_id::text)->>'addedBy',
                    p_user_id::text
                )
            )
        );
    END LOOP;

    -- Update thread — fires file_thread_priority_peers trigger
    UPDATE thread
    SET contacts = v_new_contacts,
        contact_meta = v_new_meta
    WHERE id = p_thread_id;

    -- For each newly-added contact linked to a user, create thread_state
    -- so the thread appears as unread for them. The default booleans
    -- (active/task/to_read = FALSE) and importance (50) come from the
    -- table defaults.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(p_add_contact_ids) AS arr(contact_id)
        JOIN user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM p_user_id
    LOOP
        -- Assign a deterministic state_order on insert. NULL state_order
        -- makes the Flutter Doing/unread-cluster drag-reorder land at the
        -- end of the null-order group instead of where the user released
        -- it (see Thread.order's doc for the full failure mode). Format
        -- mirrors Flutter's Order.first(): `-millisecondsSinceEpoch +
        -- random()` so new rows sort near the top of their cluster in
        -- ascending order.
        INSERT INTO thread_state (user_id, thread_id, "order")
        VALUES (
            r.peer_user_id,
            p_thread_id,
            (-EXTRACT(EPOCH FROM clock_timestamp()) * 1000) + random()
        )
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    -- Collect contact_ids that need invitation emails (not linked to any user)
    SELECT COALESCE(array_agg(arr.contact_id), ARRAY[]::uuid[])
    INTO v_needs_invitation
    FROM unnest(p_add_contact_ids) AS arr(contact_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM user_contact uc
        WHERE uc.contact_id = arr.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
    );

    RETURN jsonb_build_object(
        'contacts', to_jsonb(v_new_contacts),
        'contact_meta', v_new_meta,
        'needs_invitation', to_jsonb(v_needs_invitation)
    );
END;
$$;
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "pending_contacts",
  "contact_meta",
  "seq",
  "last_note_seq",
  "merged_into_thread_id"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    groups,
    topic,
    embedding,
    twist_id,
    pending_contacts,
    contact_meta,
    seq,
    last_note_seq,
    merged_into_thread_id
   FROM public.thread a;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "auto_archived_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.contact_meta,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.auto_archived_by_thread_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    COALESCE(ts.task, false) AS task,
    COALESCE(ts.to_read, false) AS to_read,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ts.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     JOIN public.priority p ON p.id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (p.team_id IS NULL OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Create "thread_redacted" view
CREATE VIEW "user"."thread_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "auto_archived_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    tp.revoked_at AS updated_at,
    tp.seq,
    a.updated_by,
    tp.revoked_at AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    ARRAY[]::uuid[] AS contacts,
    '{}'::jsonb AS contact_meta,
    ARRAY[]::uuid[] AS groups,
    NULL::text AS topic,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::text AS icon,
    NULL::uuid AS merged_into_thread_id,
    false AS has_embedding,
    NULL::uuid AS auto_archived_by_thread_id,
    NULL::timestamp with time zone AS last_note_created_at,
    NULL::timestamp with time zone AS last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    false AS active,
    false AS task,
    false AS to_read,
    NULL::boolean AS urgent,
    NULL::double precision AS state_order,
    NULL::daterange AS state_on,
    NULL::tstzrange AS state_at,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at,
    true AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
  WHERE tp.revoked_at IS NOT NULL;
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nt_1.tag_id,
                    jsonb_agg(nt_1.actor_id ORDER BY nt_1.actor_id) FILTER (WHERE nt_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nt_1.archived_at, nt_1.updated_at)) AS updated_at,
                    max(nt_1.seq) AS seq
                   FROM public.note_tag nt_1
                  WHERE nt_1.note_id = n.id
                  GROUP BY nt_1.tag_id) sq
         HAVING count(*) > 0) nt ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    tt.seq,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                    max(at.seq) AS seq
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Drop "share_thread" function
DROP FUNCTION "public"."share_thread" (uuid, uuid, uuid[], uuid[]);

-- Bump non-archived threads so existing clients re-pull and pick up the new
-- contact_meta column on user.thread (see libs/db/AGENTS.md "Also bump on
-- schema changes that add view columns").
UPDATE thread SET updated_at = now() WHERE archived_at IS NULL;

-- Recreate reaction views dropped above. These currently live only in the
-- local DB (the underlying thread_reaction / note_reaction tables are
-- locally-applied WIP, not yet in schema/). Recreated here so this
-- migration is self-contained; once the WIP lands in schema/ Atlas will
-- own these definitions.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'thread_reaction') THEN
        EXECUTE $v$
            CREATE OR REPLACE VIEW "user"."thread_reactions" AS
            SELECT ua.user_id,
                ua.id,
                ua.archived_at,
                tr.occurrence,
                tr.updated_at,
                tr.seq,
                ua.priority_id,
                ua.priority_path,
                tr.reactions
            FROM "user".thread ua
            JOIN LATERAL (
                SELECT sq.occurrence,
                    jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
                    max(sq.updated_at) AS updated_at,
                    max(sq.seq) AS seq
                FROM (
                    SELECT tr_1.occurrence,
                        tr_1.emoji,
                        jsonb_agg(tr_1.actor_id) FILTER (WHERE tr_1.archived_at IS NULL) AS actor_ids,
                        max(COALESCE(tr_1.archived_at, tr_1.updated_at)) AS updated_at,
                        max(tr_1.seq) AS seq
                    FROM thread_reaction tr_1
                    WHERE tr_1.thread_id = ua.id
                    GROUP BY tr_1.occurrence, tr_1.emoji
                ) sq
                GROUP BY sq.occurrence
            ) tr ON true
        $v$;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'note_reaction') THEN
        EXECUTE $v$
            CREATE OR REPLACE VIEW "user"."note_reactions" AS
            SELECT ua.user_id,
                n.id,
                nr.updated_at,
                nr.seq,
                ua.archived_at,
                ua.priority_id,
                ua.priority_path,
                nr.reactions
            FROM "user".thread ua
            JOIN note n ON n.thread_id = ua.id
            JOIN LATERAL (
                SELECT jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
                    max(sq.updated_at) AS updated_at,
                    max(sq.seq) AS seq
                FROM (
                    SELECT nr_1.emoji,
                        jsonb_agg(nr_1.actor_id ORDER BY nr_1.actor_id) FILTER (WHERE nr_1.archived_at IS NULL) AS actor_ids,
                        max(COALESCE(nr_1.archived_at, nr_1.updated_at)) AS updated_at,
                        max(nr_1.seq) AS seq
                    FROM note_reaction nr_1
                    WHERE nr_1.note_id = n.id
                    GROUP BY nr_1.emoji
                ) sq
                HAVING count(*) > 0
            ) nr ON true
            WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id))
        $v$;
    END IF;
END;
$$;
