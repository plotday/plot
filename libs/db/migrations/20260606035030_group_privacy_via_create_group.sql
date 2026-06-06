-- Drop "derive_group_privacy" trigger
DROP TRIGGER "derive_group_privacy" ON "public"."group";
-- Drop "create_group" function
DROP FUNCTION "public"."create_group" (uuid, text, "public"."group_type", "public"."group_join_policy", bigint, uuid[]);
-- Create "create_group" function
CREATE FUNCTION "public"."create_group" ("p_user_id" uuid, "p_name" text, "p_type" "public"."group_type" DEFAULT 'private', "p_join_policy" "public"."group_join_policy" DEFAULT 'member', "p_team_id" bigint DEFAULT NULL::bigint, "p_member_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_privacy" "public"."group_privacy" DEFAULT NULL::public.group_privacy) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_group_id uuid;
    v_privacy group_privacy;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;

    -- privacy is now caller-set; fall back to deriving from the legacy type
    -- (announce -> private, else open) when the caller doesn't specify it.
    v_privacy := COALESCE(p_privacy,
        CASE WHEN p_type = 'announce' THEN 'private'::group_privacy ELSE 'open'::group_privacy END);

    INSERT INTO "group" (name, type, join_policy, team_id, created_by, privacy)
    VALUES (p_name, p_type, p_join_policy, p_team_id, p_user_id, v_privacy)
    RETURNING id INTO v_group_id;

    INSERT INTO group_admin (group_id, user_id)
    VALUES (v_group_id, p_user_id);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO group_member (group_id, contact_id)
        SELECT v_group_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_group_id;
END;
$$;
-- Drop "derive_group_privacy" function
DROP FUNCTION "public"."derive_group_privacy";
