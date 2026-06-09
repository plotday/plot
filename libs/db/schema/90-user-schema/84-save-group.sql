-- Create or update a group from a single client row. Offline-queued via
-- POST /sync/groups. One upsert that diffs the incoming row against the DB:
--   * new id      -> CREATE (client-provided UUID; creator becomes admin; seed
--                    members from member_contact_ids). type defaults to private.
--   * existing id -> apply deltas:
--       - rename (admin-only),
--       - membership diff (only when the caller can see the full roster -- admins
--         always, open-group members otherwise -- because a private-group
--         non-admin's local roster is an empty array and would otherwise look
--         like "remove everyone"). The UPDATE diff path reuses
--         public.add_group_members / public.remove_group_members so its
--         join-policy authz is identical to those helpers. (The CREATE path
--         below does NOT use those helpers -- it seeds members with a raw
--         INSERT, like public.create_group, since the creator is admin by
--         construction.)
--   privacy/type changes on update are ignored.
-- Rejects auto_maintained groups. The CREATE path (and the UPDATE add-path,
-- via public.add_group_members) rejects members without an email via
-- public.assert_group_members_have_email. Returns the group id.
CREATE OR REPLACE FUNCTION "user".save_group (
    user_id uuid,
    p_group jsonb
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
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
$function$;
