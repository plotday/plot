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

    -- Create Using Plot (@plot.app). Config pins new threads to the
    -- feedback topic, auto-shares them with the Plot team, and hides the
    -- agenda tab so the priority acts like a feedback channel.
    --
    -- Group resolution: prefer the full "Plot" team's auto-maintained group
    -- (everyone on the team, what we want in prod). Fall back to the Plot
    -- publisher admin group (developers only) for environments where the
    -- Plot team doesn't exist yet — this feature isn't meaningfully used
    -- outside prod, so the narrower audience is acceptable. The
    -- `groupLabel` is what the UI renders on the locked chip, decoupled
    -- from whatever the underlying group happens to be named locally.
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon, config)
    VALUES (
        p_user_id,
        p_user_id,
        'Using Plot',
        v_new_path || generate_path(NULL),
        7,
        '@plot.app',
        'https://plot.day/assets/plot-icon.svg',
        jsonb_build_object(
            'topic', 'feedback',
            'group', COALESCE(
                (
                    SELECT g.id::text FROM public.group g
                    JOIN public.team t ON t.id = g.team_id
                    WHERE g.auto_maintained = TRUE
                      AND g.auto_team_admin_team_id IS NULL
                      AND t.name = 'Plot'
                    LIMIT 1
                ),
                (
                    SELECT g.id::text FROM public.group g
                    WHERE g.auto_maintained = TRUE
                      AND g.auto_publisher_id = (SELECT id FROM public.publisher WHERE name = 'Plot' LIMIT 1)
                    LIMIT 1
                )
            ),
            'groupLabel', 'Plot Team',
            'view', 'activity'
        )
    );

    -- Twist Development (@plot.twist-dev) is created lazily on first deploy
    -- via ensure_twist_dev_priority, so users who never develop twists don't
    -- carry an unused priority.

    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;

-- Backfill existing Using Plot priorities with the prod-preferred group
-- resolution (full Plot team → Plot publisher admins fallback) and the
-- "Plot Team" display label.
UPDATE "public"."priority"
SET config = jsonb_build_object(
    'topic', 'feedback',
    'group', COALESCE(
        (
            SELECT g.id::text FROM public."group" g
            JOIN public.team t ON t.id = g.team_id
            WHERE g.auto_maintained = TRUE
              AND g.auto_team_admin_team_id IS NULL
              AND t.name = 'Plot'
            LIMIT 1
        ),
        (
            SELECT g.id::text FROM public."group" g
            WHERE g.auto_maintained = TRUE
              AND g.auto_publisher_id = (SELECT id FROM public.publisher WHERE name = 'Plot' LIMIT 1)
            LIMIT 1
        )
    ),
    'groupLabel', 'Plot Team',
    'view', 'activity'
)
WHERE key = '@plot.app';
