-- Create "assert_group_members_have_email" function
CREATE FUNCTION "public"."assert_group_members_have_email" ("p_contact_ids" uuid[]) RETURNS void LANGUAGE plpgsql STABLE SET "search_path" = public AS $$
BEGIN
    IF p_contact_ids IS NULL OR cardinality(p_contact_ids) = 0 THEN
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM contact
        WHERE id = ANY(p_contact_ids)
          AND (email IS NULL OR btrim(email) = '')
    ) THEN
        RAISE EXCEPTION 'All group members must have an email address';
    END IF;
END;
$$;
-- Modify "add_group_members" function
CREATE OR REPLACE FUNCTION "public"."add_group_members" ("p_user_id" uuid, "p_group_id" uuid, "p_contact_ids" uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF v_group.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained group';
    END IF;

    IF v_group.join_policy = 'admin' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add members to this group';
        END IF;
    ELSIF v_group.join_policy = 'member' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) AND NOT EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only members can add members to this group';
        END IF;
    END IF;

    PERFORM public.assert_group_members_have_email(p_contact_ids);

    INSERT INTO group_member (group_id, contact_id)
    SELECT p_group_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
END;
$$;
-- Modify "create_group" function
CREATE OR REPLACE FUNCTION "public"."create_group" ("p_user_id" uuid, "p_name" text, "p_type" "public"."group_type" DEFAULT 'private', "p_join_policy" "public"."group_join_policy" DEFAULT 'member', "p_team_id" bigint DEFAULT NULL::bigint, "p_member_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_privacy" "public"."group_privacy" DEFAULT NULL::public.group_privacy) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public AS $$
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

    PERFORM public.assert_group_members_have_email(p_member_contact_ids);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO group_member (group_id, contact_id)
        SELECT v_group_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_group_id;
END;
$$;
-- Modify "save_group" function
CREATE OR REPLACE FUNCTION "user"."save_group" ("user_id" uuid, "p_group" jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_group_id uuid := (p_group ->> 'id')::uuid;
    v_name text := p_group ->> 'name';
    v_privacy group_privacy := COALESCE((p_group ->> 'privacy')::group_privacy, 'open');
    v_member_ids uuid[] := COALESCE(
        (SELECT array_agg(value::uuid)
         FROM jsonb_array_elements_text(p_group -> 'member_contact_ids')),
        ARRAY[]::uuid[]);
    v_existing "group"%ROWTYPE;
    v_is_admin boolean;
    v_roster_visible boolean;
    v_to_add uuid[];
    v_to_remove uuid[];
BEGIN
    IF v_group_id IS NULL THEN
        RAISE EXCEPTION 'Group id is required';
    END IF;

    SELECT * INTO v_existing FROM "group" WHERE id = v_group_id;

    -- CREATE
    IF v_existing.id IS NULL THEN
        IF v_name IS NULL OR length(btrim(v_name)) = 0 THEN
            RAISE EXCEPTION 'Group name is required';
        END IF;

        -- Client-created groups are always type='private': the legacy `type`
        -- column is not client-controllable (`privacy` is the real axis), so
        -- any `type` in the payload is intentionally ignored.
        INSERT INTO "group" (id, name, type, privacy, created_by)
        VALUES (v_group_id, v_name, 'private', v_privacy, save_group.user_id);

        INSERT INTO group_admin (group_id, user_id)
        VALUES (v_group_id, save_group.user_id);

        PERFORM public.assert_group_members_have_email(v_member_ids);

        IF cardinality(v_member_ids) > 0 THEN
            INSERT INTO group_member (group_id, contact_id)
            SELECT v_group_id, unnest(v_member_ids)
            ON CONFLICT DO NOTHING;
        END IF;

        RETURN v_group_id;
    END IF;

    -- UPDATE
    IF v_existing.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify auto-maintained group';
    END IF;

    v_is_admin := EXISTS (
        SELECT 1 FROM group_admin ga
        WHERE ga.group_id = v_group_id AND ga.user_id = save_group.user_id);

    -- Rename (admin-only)
    IF v_name IS NOT NULL AND v_name IS DISTINCT FROM v_existing.name THEN
        IF NOT v_is_admin THEN
            RAISE EXCEPTION 'Only admins can rename this group';
        END IF;
        IF length(btrim(v_name)) = 0 THEN
            RAISE EXCEPTION 'Group name is required';
        END IF;
        UPDATE "group" SET name = v_name WHERE id = v_group_id;
    END IF;

    -- Membership diff, only for callers with an accurate local roster.
    v_roster_visible := v_is_admin OR (
        v_existing.privacy = 'open' AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = v_group_id AND uc.user_id = save_group.user_id));

    IF (p_group ? 'member_contact_ids') AND v_roster_visible THEN
        SELECT array_agg(c) INTO v_to_add
        FROM unnest(v_member_ids) c
        WHERE NOT EXISTS (
            SELECT 1 FROM group_member gm
            WHERE gm.group_id = v_group_id AND gm.contact_id = c);

        SELECT array_agg(gm.contact_id) INTO v_to_remove
        FROM group_member gm
        WHERE gm.group_id = v_group_id
          AND gm.contact_id <> ALL (v_member_ids);

        IF v_to_add IS NOT NULL AND cardinality(v_to_add) > 0 THEN
            PERFORM public.add_group_members(save_group.user_id, v_group_id, v_to_add);
        END IF;
        IF v_to_remove IS NOT NULL AND cardinality(v_to_remove) > 0 THEN
            PERFORM public.remove_group_members(save_group.user_id, v_group_id, v_to_remove);
        END IF;
    END IF;

    RETURN v_group_id;
END;
$$;
