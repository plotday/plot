-- Migrate the global "Everyone" broadcast into "Plot Users" (group) + a
-- "Plot Updates" announce topic over it, and repoint the 7 global onboarding
-- threads onto that topic. Idempotent + guarded (safe to re-run on prod).
DO $$
DECLARE
    v_plot_users_id uuid;
    v_plot_updates_id uuid;
    v_author_id uuid;
BEGIN
    SELECT id, created_by INTO v_plot_users_id, v_author_id
    FROM "group"
    WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL
      AND auto_team_admin_team_id IS NULL;
    IF v_plot_users_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE "group"
    SET name = 'Plot Users', privacy = 'private'
    WHERE id = v_plot_users_id AND (name <> 'Plot Users' OR privacy <> 'private');

    SELECT id INTO v_plot_updates_id FROM topic WHERE key = '@plot.updates';
    IF v_plot_updates_id IS NULL THEN
        INSERT INTO topic (name, announce, auto_maintained, key, created_by)
        VALUES ('Plot Updates', TRUE, TRUE, '@plot.updates', v_author_id)
        RETURNING id INTO v_plot_updates_id;
    END IF;
    INSERT INTO topic_group (topic_id, group_id) VALUES (v_plot_updates_id, v_plot_users_id)
    ON CONFLICT DO NOTHING;
    INSERT INTO topic_admin (topic_id, user_id) VALUES (v_plot_updates_id, v_author_id)
    ON CONFLICT DO NOTHING;

    UPDATE thread
    SET topic_id = v_plot_updates_id,
        topic = 'topic:' || v_plot_updates_id::text,
        groups = array_remove(COALESCE(groups, ARRAY[]::uuid[]), v_plot_users_id)
    WHERE key IN ('welcome','priorities','connections','getting-around',
                  'twists','notifications','clean-up')
      AND archived_at IS NULL
      AND topic_id IS DISTINCT FROM v_plot_updates_id;
END $$;
