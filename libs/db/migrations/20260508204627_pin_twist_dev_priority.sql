-- Modify "ensure_twist_dev_priority" function
CREATE OR REPLACE FUNCTION "public"."ensure_twist_dev_priority" ("p_user_id" uuid) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_root_path ltree;
BEGIN
    SELECT id INTO v_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND key = '@plot.twist-dev'
      AND archived_at IS NULL
    LIMIT 1;

    IF v_priority_id IS NOT NULL THEN
        RETURN v_priority_id;
    END IF;

    SELECT path INTO v_root_path
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
      AND archived_at IS NULL
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_path IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.priority (created_by, user_id, title, path, color, key, config)
    VALUES (
        p_user_id,
        p_user_id,
        'Twist Development',
        v_root_path || generate_path(NULL),
        3,
        '@plot.twist-dev',
        jsonb_build_object('view', 'activity')
    )
    RETURNING id INTO v_priority_id;

    -- Pin Twist Development just above Using Plot. Same rationale as the
    -- @plot.app pinning in activate_invited_user: the view's epoch fallback
    -- would float this priority above anything the user creates later.
    -- 1e14 sits well past any plausible epoch_ms value but stays below
    -- @plot.app's 1e15, so the order is: user priorities, Twist Dev,
    -- Using Plot.
    INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES (p_user_id, v_priority_id, 'order', to_jsonb(1e14::double precision));

    RETURN v_priority_id;
END;
$$;

-- Backfill: pin every existing Twist Development priority just above Using
-- Plot. Skip rows that already have an explicit order setting so we don't
-- clobber someone who deliberately reordered.
INSERT INTO public.priority_setting (user_id, priority_id, key, value)
SELECT p.user_id, p.id, 'order', to_jsonb(1e14::double precision)
FROM public.priority p
WHERE p.key = '@plot.twist-dev'
  AND NOT EXISTS (
    SELECT 1 FROM public.priority_setting ps
    WHERE ps.user_id = p.user_id
      AND ps.priority_id = p.id
      AND ps.key = 'order'
  );

-- Bump priority.updated_at so clients re-pull and pick up the new computed
-- order from the user.priority view.
UPDATE public.priority
SET updated_at = now()
WHERE key = '@plot.twist-dev';
