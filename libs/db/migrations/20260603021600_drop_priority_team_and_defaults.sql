-- Drop "priority" view (CASCADE to drop dependent function user.upsert_priority,
-- which depends on the view's composite type and is recreated below). Atlas's
-- diff omits CASCADE here; matches the precedent in
-- 20260309004717_add_organization_id_to_priority.sql.
DROP VIEW IF EXISTS "user"."priority" CASCADE;
-- Drop the priority_team_* triggers BEFORE dropping priority.team_id: their
-- WHEN (OLD.team_id IS DISTINCT FROM NEW.team_id) clauses depend on the column.
-- (Atlas emits the column drop first, which fails — reordered manually.)
-- Drop "priority_team_inherit" trigger
DROP TRIGGER "priority_team_inherit" ON "public"."priority";
-- Drop "priority_team_cascade" trigger
DROP TRIGGER "priority_team_cascade" ON "public"."priority";
-- Drop "priority_team_lock" trigger
DROP TRIGGER "priority_team_lock" ON "public"."priority";
-- Drop "team_user_ensure_team_priority" trigger
DROP TRIGGER "team_user_ensure_team_priority" ON "public"."team_user";
-- Drop "team_user_archive_priorities" trigger
DROP TRIGGER "team_user_archive_priorities" ON "public"."team_user";
-- Recreate "user".priority_unread BEFORE the column drop: the OLD view
-- references priority.team_id, so it must be redefined off the column first.
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
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (a.team_id IS NULL OR a.external_contacts && "user".user_contact_ids(tp.user_id) OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = a.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)))
     JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id AND ts.read_at IS NULL AND (ts.importance >= 50 OR ts.urgent = true)
  GROUP BY tp.user_id, ("user".effective_priority_id(tp.priority_id, tp.user_id));

-- Modify "priority" table (after the team triggers above are gone)
ALTER TABLE "public"."priority" DROP COLUMN "default_contacts", DROP COLUMN "default_groups", DROP COLUMN "default_invite_emails", DROP COLUMN "team_id";
-- Create "team_user_revoke_team_threads" function
CREATE FUNCTION "public"."team_user_revoke_team_threads" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Revoke the leaving user's access to this team's threads (keyed on the
    -- thread's own team_id). External (customer) contacts are exempt — they
    -- keep access even after the user leaves the team.
    UPDATE public.thread_priority tp
    SET revoked_at = now()
    FROM public.thread t
    WHERE tp.thread_id = t.id
      AND tp.user_id = NEW.user_id
      AND t.team_id = NEW.team_id
      AND NOT (t.external_contacts && "user".user_contact_ids(NEW.user_id))
      AND tp.revoked_at IS NULL;
    RETURN NULL;
END;
$$;
-- Create trigger "team_user_revoke_team_threads"
CREATE TRIGGER "team_user_revoke_team_threads" AFTER UPDATE ON "public"."team_user" FOR EACH ROW WHEN ((old.archived_at IS NULL) AND (new.archived_at IS NOT NULL)) EXECUTE FUNCTION "public"."team_user_revoke_team_threads"();
-- Modify "classify_thread_for_user_explain" function
CREATE OR REPLACE FUNCTION "public"."classify_thread_for_user_explain" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topic" text DEFAULT NULL::text, "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_groups" uuid[] DEFAULT NULL::uuid[]) RETURNS TABLE ("priority_id" uuid, "stage" text, "scores" jsonb) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_contacts uuid[];
    v_groups uuid[];
    v_matched uuid;
    v_scores jsonb;
    v_channel_pk bigint;
    v_priority_key text;
BEGIN
    -- 1. Load thread signals when an id was supplied.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic, t.contacts, t.groups
        INTO v_embedding, v_topic, v_contacts, v_groups
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);
    v_groups    := COALESCE(p_groups, v_groups, ARRAY[]::uuid[]);

    -- 2. Topic short-circuit on user_moved siblings.
    IF v_topic IS NOT NULL THEN
        SELECT tp.priority_id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
          AND mt.topic = v_topic
        GROUP BY tp.priority_id
        ORDER BY COUNT(*) DESC, MAX(tp.updated_at) DESC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            RETURN QUERY SELECT v_matched,
                                'topic_shortcircuit'::text,
                                jsonb_build_object('topic', v_topic);
            RETURN;
        END IF;
    END IF;

    -- 2.3. Cross-user keyed priority match.
    IF p_thread_id IS NOT NULL THEN
        SELECT p.id INTO v_matched
        FROM public.thread_priority tp
        JOIN public.priority src ON src.id = tp.priority_id
        JOIN public.priority p
          ON p.user_id = p_user_id
         AND p.key = src.key
         AND p.archived_at IS NULL
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id <> p_user_id
          AND src.key IS NOT NULL
          AND src.archived_at IS NULL
        ORDER BY tp.created_at ASC
        LIMIT 1;
        IF v_matched IS NOT NULL THEN
            SELECT jsonb_build_object('key', p.key)
            INTO v_scores
            FROM public.priority p
            WHERE p.id = v_matched;
            RETURN QUERY SELECT v_matched,
                                'keyed_priority'::text,
                                COALESCE(v_scores, '{}'::jsonb);
            RETURN;
        END IF;
    END IF;

    -- 2.5. Channel default.
    IF v_topic LIKE 'channel:%' THEN
        BEGIN
            v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
            IF v_channel_pk IS NOT NULL THEN
                SELECT c.default_priority_id INTO v_matched
                FROM public.channel c
                JOIN public.priority p ON p.id = c.default_priority_id
                WHERE c.id = v_channel_pk
                  AND c.default_priority_id IS NOT NULL
                  AND p.user_id = p_user_id
                  AND p.archived_at IS NULL;
                IF v_matched IS NOT NULL THEN
                    RETURN QUERY SELECT v_matched,
                                        'channel_default'::text,
                                        jsonb_build_object('channel_id', v_channel_pk);
                    RETURN;
                END IF;
            END IF;
        EXCEPTION WHEN invalid_text_representation THEN
            NULL;
        END;
    END IF;

    -- 3. Score all moved threads when no topic match was available.
    WITH moved AS (
        SELECT tp.priority_id,
               tp.thread_id,
               mt.embedding,
               mt.contacts,
               mt.groups
        FROM public.thread_priority tp
        JOIN public.thread mt ON mt.id = tp.thread_id
        WHERE tp.user_id = p_user_id
          AND tp.user_moved = TRUE
          AND mt.archived_at IS NULL
    ),
    candidate AS (
        SELECT public.expand_contacts(v_contacts) AS exp_contacts,
               v_groups AS groups,
               v_embedding AS embedding
    ),
    -- Negative examples per priority: max cosine similarity between the
    -- candidate and threads the user moved out of / deselected for that focus.
    -- Subtracted from the priority's combined score below (mirror of the
    -- user_moved positive set; see thread_priority_negative).
    neg AS (
        SELECT n.priority_id,
               MAX(GREATEST(0, 1 - (nt.embedding <=> v_embedding))) AS neg_sim
        FROM public.thread_priority_negative n
        JOIN public.thread nt ON nt.id = n.thread_id
        WHERE n.user_id = p_user_id
          AND nt.archived_at IS NULL
          AND nt.embedding IS NOT NULL
          AND v_embedding IS NOT NULL
        GROUP BY n.priority_id
    ),
    scored AS (
        SELECT
            f.priority_id,
            f.thread_id,
            COALESCE(ng.neg_sim, 0) AS neg_sim,
            CASE
                WHEN f.embedding IS NULL OR c.embedding IS NULL THEN 0
                ELSE POWER(
                    GREATEST(0, (1 - (f.embedding <=> c.embedding)) - 0.5) * 2,
                    2
                )
            END AS sem,
            CASE
                WHEN cardinality(f.contacts) = 0 OR cardinality(c.exp_contacts) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        INTERSECT
                        SELECT unnest(c.exp_contacts)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(public.expand_contacts(f.contacts))
                        UNION
                        SELECT unnest(c.exp_contacts)
                    )), 0),
                    2
                )
            END AS con,
            CASE
                WHEN cardinality(f.groups) = 0 OR cardinality(c.groups) = 0 THEN 0
                ELSE POWER(
                    cardinality(ARRAY(
                        SELECT unnest(f.groups) INTERSECT SELECT unnest(c.groups)
                    ))::numeric
                    / NULLIF(cardinality(ARRAY(
                        SELECT unnest(f.groups) UNION SELECT unnest(c.groups)
                    )), 0),
                    2
                )
            END AS grp
        FROM moved f
        CROSS JOIN candidate c
        LEFT JOIN neg ng ON ng.priority_id = f.priority_id
    )
    SELECT jsonb_build_object(
        'top', COALESCE(jsonb_agg(
            jsonb_build_object(
                'priority_id', top_scored.pid,
                'thread_id', top_scored.tid,
                'sem', round(top_scored.sem::numeric, 4),
                'con', round(top_scored.con::numeric, 4),
                'grp', round(top_scored.grp::numeric, 4),
                'combined', round((0.5 * top_scored.sem + 0.35 * top_scored.con + 0.15 * top_scored.grp - 0.3 * top_scored.neg_sim)::numeric, 4)
            )
            ORDER BY (0.5 * top_scored.sem + 0.35 * top_scored.con + 0.15 * top_scored.grp - 0.3 * top_scored.neg_sim) DESC
        ), '[]'::jsonb)
    )
    INTO v_scores
    FROM (
        SELECT scored.priority_id AS pid,
               scored.thread_id AS tid,
               scored.sem,
               scored.con,
               scored.grp,
               scored.neg_sim
        FROM scored
        ORDER BY (0.5 * scored.sem + 0.35 * scored.con + 0.15 * scored.grp - 0.3 * scored.neg_sim) DESC
        LIMIT 3
    ) top_scored;

    SELECT (x.priority_id)::uuid INTO v_matched
    FROM jsonb_to_recordset(v_scores->'top')
        AS x(priority_id uuid, combined numeric)
    WHERE x.combined >= 0.15
    ORDER BY x.combined DESC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'scoring'::text,
                            COALESCE(v_scores, '{}'::jsonb);
        RETURN;
    END IF;

    -- 5. priority:{KEY}[:{SUB_TOPIC}] prefix.
    IF v_topic LIKE 'priority:%' THEN
        v_priority_key := split_part(v_topic, ':', 2);
        IF v_priority_key <> '' THEN
            SELECT p.id INTO v_matched
            FROM public.priority p
            WHERE p.user_id = p_user_id
              AND p.key = v_priority_key
              AND p.archived_at IS NULL
            LIMIT 1;
            IF v_matched IS NOT NULL THEN
                RETURN QUERY SELECT v_matched,
                                    'priority_prefix'::text,
                                    jsonb_build_object('key', v_priority_key);
                RETURN;
            END IF;
        END IF;
    END IF;

    -- 6. Root fallback. Focuses are team-agnostic, so every unmatched thread
    -- (personal or team-connector) routes to the user's root priority (oldest
    -- non-archived depth-1). Team scope is enforced by the user.thread
    -- visibility firewall on thread.team_id, not by where the thread is filed.
    SELECT p.id INTO v_matched
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    IF v_matched IS NOT NULL THEN
        RETURN QUERY SELECT v_matched,
                            'root_fallback'::text,
                            '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT NULL::uuid,
                        'none'::text,
                        '{}'::jsonb;
    RETURN;
END;
$$;
-- Set comment to function: "classify_thread_for_user_explain"
COMMENT ON FUNCTION "public"."classify_thread_for_user_explain" IS 'Verbose classifier returning (priority_id, stage, scores). Same algorithm as classify_thread_for_user; the stage column attributes the match to one of: topic_shortcircuit, keyed_priority, channel_default, scoring, priority_prefix, root_fallback, none. Focuses are team-agnostic, so classification does not restrict candidates by team — team scope is enforced by the user.thread visibility firewall on thread.team_id.';
-- Set comment to function: "classify_thread_for_user"
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority. Thin wrapper around classify_thread_for_user_explain. Order: (1) topic short-circuit on user_moved siblings, (2) cross-user keyed priority match (file under recipient''s same-keyed priority when another user already filed there), (3) channel.default_priority_id when topic is ''channel:<pk>'', (4) semantic/contact/group scoring against user_moved examples, (5) priority:{KEY} prefix, (6) root priority fallback. Focuses are team-agnostic; team scope is enforced by the user.thread visibility firewall on thread.team_id.';
-- Create "priority" view
CREATE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread",
  "role",
  "respond_schedule_enabled",
  "respond_window",
  "respond_within",
  "early_notifications_enabled",
  "notify_window",
  "see_within",
  "respond_schedule_enabled_set",
  "respond_window_set",
  "respond_within_set",
  "early_notifications_enabled_set",
  "notify_window_set",
  "see_within_set",
  "inherit_members",
  "config",
  "icon",
  "flat_title"
) AS WITH user_root AS (
         SELECT DISTINCT ON (p_1.user_id) p_1.user_id,
            p_1.id AS root_id,
            p_1.path AS root_path
           FROM public.priority p_1
          WHERE public.nlevel(p_1.path) = 1
          ORDER BY p_1.user_id, p_1.created_at
        ), direct_settings AS (
         SELECT priority_setting.user_id,
            priority_setting.priority_id,
            max(
                CASE
                    WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS top_order,
            max(
                CASE
                    WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS "order",
            max(
                CASE
                    WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS title,
            max(
                CASE
                    WHEN priority_setting.key = 'color'::text THEN (priority_setting.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_schedule_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_schedule_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_within_set,
            max(
                CASE
                    WHEN priority_setting.key = 'early_notifications_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS early_notifications_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'notify_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS notify_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id
        ), inherited_settings AS (
         SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_schedule_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS respond_schedule_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_within,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'early_notifications_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS early_notifications_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'notify_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS notify_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.seq,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    COALESCE(direct.color, p.color) AS color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.respond_schedule_enabled,
    inh.respond_window,
    inh.respond_within,
    inh.early_notifications_enabled,
    inh.notify_window,
    inh.see_within,
    COALESCE(direct.respond_schedule_enabled_set, false) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, false) AS respond_window_set,
    COALESCE(direct.respond_within_set, false) AS respond_within_set,
    COALESCE(direct.early_notifications_enabled_set, false) AS early_notifications_enabled_set,
    COALESCE(direct.notify_window_set, false) AS notify_window_set,
    COALESCE(direct.see_within_set, false) AS see_within_set,
    p.inherit_members,
    p.config,
    p.icon,
    ( SELECT string_agg(a.title, ' › '::text ORDER BY (public.nlevel(a.path))) AS string_agg
           FROM public.priority a
          WHERE a.user_id = p.user_id AND a.path OPERATOR(public.@>) p.path AND public.nlevel(a.path) >= 2) AS flat_title
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
-- Recreate "user".upsert_priority (dropped by CASCADE on the view above;
-- moved after the view recreate so its RETURNS "user"."priority" resolves).
CREATE OR REPLACE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority";
    _old "user"."priority";
    v_row "user"."priority";
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _is_move boolean;
    _priority_exists boolean;
    _old_path ltree;
BEGIN
    -- Extract input fields from JSONB into the view's row type
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = _input.id) INTO _priority_exists;
    -- Viewer enforcement: viewers cannot create new priorities
    -- For existing priorities, allow through (only priority_settings changes like reordering)
    IF NOT _priority_exists AND nlevel(_input.path) > 1 THEN
        DECLARE
            _parent_priority_id uuid;
            _parent_path ltree;
        BEGIN
            _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            SELECT up.id INTO _parent_priority_id
            FROM "user".priority up
            WHERE up.user_id = upsert_priority.user_id AND up.path = _parent_path
            LIMIT 1;
            IF _parent_priority_id IS NOT NULL AND "user".get_effective_role(upsert_priority.user_id, _parent_priority_id) = 'viewer' THEN
                RAISE EXCEPTION 'Viewer members cannot create priorities';
            END IF;
        END;
    END IF;
    -- Look up existing row from view if it exists (replaces OLD trigger variable)
    IF _priority_exists THEN
        SELECT
            * INTO _old
        FROM
            "user".priority up
        WHERE
            up.user_id = upsert_priority.user_id
            AND up.id = _input.id;
        _old_path := _old.path;
    END IF;
    -- Flat-client compatibility: clients on the flattened model (apiVersion
    -- >= 4) have no nesting and do not send a path. Keep the existing path on
    -- update; on insert synthesize a child-of-root path so nested (old)
    -- clients can still place the new focus under the user's root. path is
    -- NOT NULL, so this must never leave it null.
    IF _input.path IS NULL THEN
        IF _priority_exists THEN
            _input.path := _old_path;
        ELSE
            DECLARE
                _root_path ltree;
            BEGIN
                SELECT
                    path INTO _root_path
                FROM priority
                WHERE user_id = upsert_priority.user_id AND nlevel(path) = 1
                ORDER BY created_at ASC
                LIMIT 1;
                IF _root_path IS NULL THEN
                    -- No root yet: treat this as the root itself.
                    _input.path := generate_path(NULL);
                ELSE
                    _input.path := _root_path || generate_path(NULL);
                END IF;
            END;
        END IF;
    END IF;
    -- Detect if this is a move (path changed on existing priority)
    _is_move := (_priority_exists
        AND _input.path IS DISTINCT FROM _old_path);
    IF _is_move THEN
        -- Prevent circular reference
        IF _input.path <@ _old_path OR _input.path = _old_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_path::text || ', new_path=' || _input.path::text;
        END IF;
        -- In the per-user model every priority belongs to a single user's
        -- tree, so every move is a straight ltree relocation.
        DECLARE
            _parent_path ltree;
        BEGIN
            IF nlevel(_input.path) > 1 THEN
                _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            ELSE
                _parent_path := NULL;
            END IF;
            PERFORM move_priority (_input.id, _parent_path);
        END;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF NOT _is_move THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, icon, path, created_by, updated_by)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.icon, _input.path, _input.created_by, _input.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                -- COALESCE: old (nested) clients don't send icon; preserve the
                -- existing value rather than wiping it on every edit.
                icon = COALESCE(_input.icon, priority.icon),
                updated_by = _input.updated_by
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields (path was already updated by move_priority)
        UPDATE
            priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN
                _input.color
            ELSE
                priority.color
            END,
            icon = COALESCE(_input.icon, priority.icon),
            updated_by = _input.updated_by
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Always upsert top_order, order, pomodoro, color if provided
    IF NOT _is_move THEN
        IF _input.top_order IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'top_order', to_jsonb(_input.top_order))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'top_order';
        END IF;
        IF _input."order" IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'order', to_jsonb(_input."order"))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        IF _input.pomodoro IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'pomodoro', to_jsonb(_input.pomodoro))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'pomodoro';
        END IF;
        IF _input.color IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'color', to_jsonb(COALESCE(_input.color, _priority_default_color)))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'color';
        END IF;
    END IF;
    -- Return the updated row from the view
    SELECT
        * INTO v_row
    FROM
        "user".priority up
    WHERE
        up.user_id = upsert_priority.user_id
        AND up.id = _input.id;
    RETURN v_row;
END;
$$;
-- Drop "priority_team_cascade" function
DROP FUNCTION "public"."priority_team_cascade";
-- Drop "priority_team_inherit" function
DROP FUNCTION "public"."priority_team_inherit";
-- Drop "priority_team_lock" function
DROP FUNCTION "public"."priority_team_lock";
-- Drop "team_user_archive_priorities" function
DROP FUNCTION "public"."team_user_archive_priorities";
-- Drop "team_user_ensure_team_priority" function
DROP FUNCTION "public"."team_user_ensure_team_priority";
