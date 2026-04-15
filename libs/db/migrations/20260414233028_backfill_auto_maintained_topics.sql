-- Backfill auto-maintained topics for existing teams and users.
DO $$
DECLARE
    v_first_admin_id uuid;
    v_everyone_topic_id uuid;
    v_team RECORD;
    v_team_topic_id uuid;
BEGIN
    -- 1. Create Everyone topic if it doesn't exist.
    -- Find a suitable creator (e.g. the first user created).
    SELECT id INTO v_first_admin_id FROM "public"."user" ORDER BY created_at ASC LIMIT 1;
    
    IF v_first_admin_id IS NULL THEN
        RETURN; -- No users exist, nothing to backfill
    END IF;

    SELECT id INTO v_everyone_topic_id
    FROM topic
    WHERE auto_maintained = TRUE AND team_id IS NULL;

    IF v_everyone_topic_id IS NULL THEN
        INSERT INTO topic (name, type, join_policy, created_by, auto_maintained)
        VALUES ('Everyone', 'announce', 'open', v_first_admin_id, TRUE)
        RETURNING id INTO v_everyone_topic_id;
    END IF;

    -- 2. Backfill existing active primary contacts into Everyone topic
    INSERT INTO topic_member (topic_id, contact_id)
    SELECT v_everyone_topic_id, uc.contact_id
    FROM user_contact uc
    WHERE uc.linked = TRUE
      AND uc."primary" = TRUE
      AND uc.archived_at IS NULL
    ON CONFLICT DO NOTHING;

    -- 3. Create Team topics for existing teams
    FOR v_team IN SELECT id, name FROM team LOOP
        -- Check if team topic already exists
        SELECT id INTO v_team_topic_id
        FROM topic
        WHERE auto_maintained = TRUE AND team_id = v_team.id;

        IF v_team_topic_id IS NULL THEN
            -- Find first admin for team
            SELECT user_id INTO v_first_admin_id
            FROM team_user
            WHERE team_id = v_team.id
            ORDER BY (role = 'admin') DESC, created_at ASC
            LIMIT 1;

            IF v_first_admin_id IS NOT NULL THEN
                INSERT INTO topic (name, type, team_id, created_by, auto_maintained)
                VALUES (v_team.name || ' Team', 'team', v_team.id, v_first_admin_id, TRUE)
                RETURNING id INTO v_team_topic_id;
            END IF;
        END IF;

        IF v_team_topic_id IS NOT NULL THEN
            -- Backfill team members
            INSERT INTO topic_member (topic_id, contact_id)
            SELECT v_team_topic_id, uc.contact_id
            FROM team_user tu
            JOIN user_contact uc ON uc.user_id = tu.user_id
              AND uc."primary" = TRUE
              AND uc.linked = TRUE
              AND uc.archived_at IS NULL
            WHERE tu.team_id = v_team.id
            ON CONFLICT DO NOTHING;

            -- Backfill team admins
            INSERT INTO topic_admin (topic_id, user_id)
            SELECT v_team_topic_id, tu.user_id
            FROM team_user tu
            WHERE tu.team_id = v_team.id
              AND tu.role = 'admin'
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END;
$$;
