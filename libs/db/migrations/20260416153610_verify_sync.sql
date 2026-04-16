-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    -- Already has a root priority?
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    -- Create Using Plot (@plot.app)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    -- Create Twist Development (@plot.twist-dev)
    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

    -- Add priority rules for auto-filing
    -- 1. Everyone topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_maintained = TRUE AND t.team_id IS NULL AND t.name = 'Everyone';

    -- 2. User account topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_user_id = p_user_id;

    -- 3. Team admin topics -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.team_user tu ON tu.team_id = t.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_team_admin_team_id IS NOT NULL;

    -- 4. Personal twists topic -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_personal_twist_user_id = p_user_id;

    -- 5. Publisher topics (where this user is a member) -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.topic_member tm ON tm.topic_id = t.id
    JOIN public.user_contact uc ON uc.contact_id = tm.contact_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_publisher_id IS NOT NULL
      AND t.auto_maintained = TRUE
      AND uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "auto_maintain_publisher_topic" function
CREATE OR REPLACE FUNCTION "public"."auto_maintain_publisher_topic" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_topic_id uuid;
    v_contact_id uuid;
BEGIN
    SELECT id INTO v_topic_id FROM topic WHERE auto_publisher_id = COALESCE(NEW.id, OLD.id);
    IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, auto_publisher_id, created_by, auto_maintained)
        VALUES (NEW.name || ' Publisher', 'private', NEW.id, NEW.created_by, TRUE)
        RETURNING id INTO v_topic_id;
    END IF;

    IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by) THEN
        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.created_by AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.created_by) ON CONFLICT DO NOTHING;
    END IF;
    -- DELETE: CASCADE on auto_publisher_id handles topic cleanup.

    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Drop "priority_child_twist" view
DROP VIEW "public"."priority_child_twist";
-- Create "priority_child_twist" view
CREATE VIEW "public"."priority_child_twist" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url"
) AS SELECT pt.id,
    pt.twist_id,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     LEFT JOIN public.publisher p ON t.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.priority_child_twist pct ON pct.id = a.created_by
  WHERE a.draft = false;
