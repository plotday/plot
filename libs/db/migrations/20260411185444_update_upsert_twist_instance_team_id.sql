-- Create "upsert_twist_instance" function
CREATE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_team_id" bigint, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row twist_instance;
BEGIN
    -- Twist instances are owned by a user and optionally billed to a team.
    -- The caller can only manage their own instances.
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    -- If a team is specified, the caller must be a member.
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND team_user.user_id = user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of team %', p_team_id;
        END IF;
    END IF;

    INSERT INTO twist_instance (id, twist_id, owner_id, team_id, name, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_twist_id, p_owner_id, p_team_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            team_id = EXCLUDED.team_id,
            options = EXCLUDED.options,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Drop "upsert_twist_instance" function
DROP FUNCTION "user"."upsert_twist_instance" (uuid, uuid, bigint, uuid, text, jsonb, timestamptz);
