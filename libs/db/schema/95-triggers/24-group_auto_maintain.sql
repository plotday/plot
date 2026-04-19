-- Auto-create a team group when a new team is created.
CREATE OR REPLACE FUNCTION public.auto_create_team_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_first_admin_id uuid;
BEGIN
    SELECT tu.user_id INTO v_first_admin_id
    FROM team_user tu
    WHERE tu.team_id = NEW.id
    ORDER BY (tu.role = 'admin') DESC, tu.created_at ASC
    LIMIT 1;

    IF v_first_admin_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
    VALUES (NEW.name || ' Team', 'team', NEW.id, v_first_admin_id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_create_team_group
    AFTER INSERT ON public.team
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_create_team_group ();

-- Keep team group membership in sync when team_user changes.
CREATE OR REPLACE FUNCTION public.auto_maintain_team_group_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
    v_team_id bigint;
    v_user_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_team_id := OLD.team_id;
        v_user_id := OLD.user_id;
    ELSE
        v_team_id := NEW.team_id;
        v_user_id := NEW.user_id;
    END IF;

    SELECT id INTO v_group_id
    FROM "group"
    WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;

    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
        SELECT t.name || ' Team', 'team', t.id, v_user_id, TRUE
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_group_id;

        IF v_group_id IS NULL THEN
            SELECT id INTO v_group_id
            FROM "group"
            WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;
        END IF;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT uc.contact_id INTO v_contact_id
    FROM user_contact uc
    WHERE uc.user_id = v_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    IF TG_OP = 'INSERT' THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_group_id, v_contact_id)
            ON CONFLICT DO NOTHING;
        END IF;
        IF NEW.role = 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_group_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM group_admin
        WHERE group_id = v_group_id AND user_id = v_user_id;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin' AND OLD.role != 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        ELSIF NEW.role != 'admin' AND OLD.role = 'admin' THEN
            DELETE FROM group_admin
            WHERE group_id = v_group_id AND user_id = v_user_id;
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_team_group_members
    AFTER INSERT OR DELETE OR UPDATE ON public.team_user
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_team_group_members ();

-- Auto-create and maintain team-admin groups.
CREATE OR REPLACE FUNCTION public.auto_maintain_team_admin_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role != 'admin' THEN
        SELECT id INTO v_group_id FROM "group" WHERE auto_team_admin_team_id = NEW.team_id;
        IF v_group_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                DELETE FROM group_member WHERE group_id = v_group_id AND contact_id = v_contact_id;
            END IF;
            DELETE FROM group_admin WHERE group_id = v_group_id AND user_id = NEW.user_id;
        END IF;
        RETURN NEW;
    END IF;

    SELECT id INTO v_group_id FROM "group" WHERE auto_team_admin_team_id = COALESCE(NEW.team_id, OLD.team_id);
    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, team_id, auto_team_admin_team_id, created_by, auto_maintained)
        SELECT t.name || ' Admins', 'team', t.id, t.id, NEW.user_id, TRUE
        FROM team t WHERE t.id = NEW.team_id
        RETURNING id INTO v_group_id;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND "primary" = TRUE;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.role = 'admin') THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id) VALUES (v_group_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO group_admin (group_id, user_id) VALUES (v_group_id, COALESCE(NEW.user_id, OLD.user_id)) ON CONFLICT DO NOTHING;
    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM group_member WHERE group_id = v_group_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM group_admin WHERE group_id = v_group_id AND user_id = OLD.user_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_team_admin_group
    AFTER INSERT OR DELETE OR UPDATE OF role ON public.team_user
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_team_admin_group ();

-- Auto-create and maintain publisher groups.
-- A publisher group's members are the users allowed to deploy twists under
-- that publisher. The publisher's creator becomes the first member + admin;
-- additional members are added via API.
CREATE OR REPLACE FUNCTION public.auto_maintain_publisher_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
BEGIN
    SELECT id INTO v_group_id FROM "group" WHERE auto_publisher_id = COALESCE(NEW.id, OLD.id);
    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, auto_publisher_id, created_by, auto_maintained)
        VALUES (NEW.name || ' Publisher', 'private', NEW.id, NEW.created_by, TRUE)
        RETURNING id INTO v_group_id;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by) THEN
        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.created_by AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id) VALUES (v_group_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO group_admin (group_id, user_id) VALUES (v_group_id, NEW.created_by) ON CONFLICT DO NOTHING;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_publisher_group
    AFTER INSERT OR DELETE OR UPDATE OF created_by ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_publisher_group ();

-- Keep the publisher group name in sync with the publisher's name.
CREATE OR REPLACE FUNCTION public.auto_rename_publisher_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE "group"
    SET name = NEW.name || ' Publisher'
    WHERE auto_publisher_id = NEW.id
      AND auto_maintained = TRUE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_rename_publisher_group
    AFTER UPDATE OF name ON public.publisher
    FOR EACH ROW
    WHEN (OLD.name IS DISTINCT FROM NEW.name)
    EXECUTE FUNCTION public.auto_rename_publisher_group ();

-- Auto-add new users to the "Everyone" group.
CREATE OR REPLACE FUNCTION public.auto_maintain_everyone_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_everyone_group_id uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.linked = TRUE AND NEW."primary" = TRUE THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        IF v_everyone_group_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_everyone_group_id, NEW.contact_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
        NEW.linked = FALSE OR NEW."primary" = FALSE OR NEW.archived_at IS NOT NULL
    )) THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        -- Only evict the contact from Everyone when no other qualifying
        -- self-link still claims it. Without this guard, deleting a
        -- source='thread' user_contact cross-link (e.g. the
        -- 20260418050000 / 20260418053000 cleanups) would cascade-remove
        -- the contact's primary owner from Everyone even though their
        -- source='self' link is still intact. This is an AFTER trigger,
        -- so for UPDATE the row's new state is already visible to the
        -- subquery — if NEW.linked=false (or primary=false, archived),
        -- it's already excluded by the qualifying predicate.
        IF v_everyone_group_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_everyone_group_id
              AND contact_id = COALESCE(OLD.contact_id, NEW.contact_id)
              AND NOT EXISTS (
                SELECT 1 FROM user_contact uc
                WHERE uc.contact_id = COALESCE(OLD.contact_id, NEW.contact_id)
                  AND uc.linked = TRUE
                  AND uc."primary" = TRUE
                  AND uc.archived_at IS NULL
              );
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_everyone_group
    AFTER INSERT OR UPDATE OR DELETE ON public.user_contact
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_everyone_group ();
