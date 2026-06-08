-- Create "save_group" function
CREATE FUNCTION "user"."save_group" ("user_id" uuid, "p_group" jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
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
-- Create "save_user_contact" function
CREATE FUNCTION "user"."save_user_contact" ("user_id" uuid, "p_contact_id" uuid, "p_email" text, "p_name" text) RETURNS SETOF "user"."actor" LANGUAGE plpgsql AS $$
-- The bare `user_id` in `ON CONFLICT (user_id, contact_id)` would otherwise be
-- ambiguous between the (conventionally named) `user_id` parameter and the
-- user_contact.user_id column. Prefer the column there; every other reference
-- in this body is already qualified (save_user_contact.user_id), so this is
-- safe.
#variable_conflict use_column
DECLARE
    v_contact_id uuid;
BEGIN
    IF p_contact_id IS NULL THEN
        RAISE EXCEPTION 'Contact id is required';
    END IF;

    IF p_email IS NOT NULL THEN
        -- Minimal email shape check, mirroring public.upsert_contacts.
        IF p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
            RAISE EXCEPTION 'Invalid email address';
        END IF;

        -- Resolve-or-create by email. On a fresh insert RETURNING yields
        -- p_contact_id; on an existing email we DO NOTHING (not DO UPDATE) so
        -- the BEFORE trigger that bumps contact.seq does NOT fire for a no-op
        -- write -- avoiding a spurious re-emit of the contact to every client.
        -- DO NOTHING means RETURNING produces no row, so v_contact_id is NULL
        -- on conflict and the fallback SELECT fetches the existing canonical id.
        -- Either way v_contact_id is the canonical id; the global name is never
        -- touched.
        INSERT INTO public.contact (id, email)
        VALUES (p_contact_id, lower(p_email))
        ON CONFLICT ON CONSTRAINT contact_email_unique DO NOTHING
        RETURNING id INTO v_contact_id;

        IF v_contact_id IS NULL THEN
            SELECT id INTO v_contact_id FROM public.contact WHERE email = lower(p_email);
        END IF;
    ELSE
        v_contact_id := p_contact_id;
        IF NOT EXISTS (SELECT 1 FROM public.contact WHERE id = v_contact_id) THEN
            RAISE EXCEPTION 'Contact not found';
        END IF;
    END IF;

    -- Explicit per-user name override. source='user' is sticky vs connectors.
    -- The DO UPDATE is guarded by `linked = false` so a rename can never
    -- overwrite the user's OWN identity row (their linked contact). This
    -- mirrors the connector path in public.upsert_user_contact_name.
    INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
    VALUES (save_user_contact.user_id, v_contact_id, false, 'user', p_name)
    ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            name = EXCLUDED.name,
            source = 'user'
        WHERE user_contact.linked = false;

    RETURN QUERY
    SELECT * FROM "user"."actor" a
    WHERE a.user_id = save_user_contact.user_id
      AND a.id = v_contact_id;
END;
$$;
