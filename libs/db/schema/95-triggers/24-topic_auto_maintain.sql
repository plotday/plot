-- Auto-create a team topic when a new team is created.
CREATE OR REPLACE FUNCTION public.auto_create_team_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_topic_id uuid;
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

    INSERT INTO topic (name, type, team_id, created_by, auto_maintained)
    VALUES (NEW.name || ' Team', 'team', NEW.id, v_first_admin_id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_create_team_topic
    AFTER INSERT ON public.team
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_create_team_topic ();

-- Keep team topic membership in sync when team_user changes.
CREATE OR REPLACE FUNCTION public.auto_maintain_team_topic_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_topic_id uuid;
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

    SELECT id INTO v_topic_id
    FROM topic
    WHERE team_id = v_team_id AND auto_maintained = TRUE;

    IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, team_id, created_by, auto_maintained)
        SELECT t.name || ' Team', 'team', t.id, v_user_id, TRUE
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_topic_id;

        IF v_topic_id IS NULL THEN
            SELECT id INTO v_topic_id
            FROM topic
            WHERE team_id = v_team_id AND auto_maintained = TRUE;
        END IF;
    END IF;

    IF v_topic_id IS NULL THEN
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
            INSERT INTO topic_member (topic_id, contact_id)
            VALUES (v_topic_id, v_contact_id)
            ON CONFLICT DO NOTHING;
        END IF;
        IF NEW.role = 'admin' THEN
            INSERT INTO topic_admin (topic_id, user_id)
            VALUES (v_topic_id, v_user_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM topic_member
            WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM topic_admin
        WHERE topic_id = v_topic_id AND user_id = v_user_id;

    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin' AND OLD.role != 'admin' THEN
            INSERT INTO topic_admin (topic_id, user_id)
            VALUES (v_topic_id, v_user_id)
            ON CONFLICT DO NOTHING;
        ELSIF NEW.role != 'admin' AND OLD.role = 'admin' THEN
            DELETE FROM topic_admin
            WHERE topic_id = v_topic_id AND user_id = v_user_id;
        END IF;
        END IF;

        RETURN COALESCE(NEW, OLD);
        END;
        $$;

        CREATE TRIGGER auto_maintain_team_topic_members
        AFTER INSERT OR DELETE OR UPDATE ON public.team_user
        FOR EACH ROW
        EXECUTE FUNCTION public.auto_maintain_team_topic_members ();

        -- Auto-create and maintain team-admin topics.
        CREATE OR REPLACE FUNCTION public.auto_maintain_team_admin_topic ()
        RETURNS TRIGGER
        LANGUAGE plpgsql
        AS $$
        DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        -- Only handle team admins
        IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role != 'admin' THEN
        -- If user is no longer an admin, remove from topic
        SELECT id INTO v_topic_id FROM topic WHERE auto_team_admin_team_id = NEW.team_id;
        IF v_topic_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                DELETE FROM topic_member WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
            END IF;
            DELETE FROM topic_admin WHERE topic_id = v_topic_id AND user_id = NEW.user_id;
        END IF;
        RETURN NEW;
        END IF;

        -- Get or create topic
        SELECT id INTO v_topic_id FROM topic WHERE auto_team_admin_team_id = COALESCE(NEW.team_id, OLD.team_id);
        IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, team_id, auto_team_admin_team_id, created_by, auto_maintained)
        SELECT t.name || ' Admins', 'team', t.id, t.id, NEW.user_id, TRUE
        FROM team t WHERE t.id = NEW.team_id
        RETURNING id INTO v_topic_id;
        END IF;

        IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
        END IF;

        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND "primary" = TRUE;

        IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.role = 'admin') THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, COALESCE(NEW.user_id, OLD.user_id)) ON CONFLICT DO NOTHING;
        ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM topic_member WHERE topic_id = v_topic_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM topic_admin WHERE topic_id = v_topic_id AND user_id = OLD.user_id;
        END IF;

        RETURN COALESCE(NEW, OLD);
        END;
        $$;

        CREATE TRIGGER auto_maintain_team_admin_topic
        AFTER INSERT OR DELETE OR UPDATE OF role ON public.team_user
        FOR EACH ROW
        EXECUTE FUNCTION public.auto_maintain_team_admin_topic ();

        -- Auto-create and maintain user topics.
        CREATE OR REPLACE FUNCTION public.auto_maintain_user_topic ()
        RETURNS TRIGGER
        LANGUAGE plpgsql
        AS $$
        DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        SELECT id INTO v_topic_id FROM topic WHERE auto_user_id = NEW.user_id;
        IF v_topic_id IS NULL THEN
        INSERT INTO topic (name, type, auto_user_id, created_by, auto_maintained)
        VALUES ('Account Topic', 'private', NEW.user_id, NEW.user_id, TRUE)
        RETURNING id INTO v_topic_id;
        END IF;

        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;

        IF v_contact_id IS NOT NULL THEN
        INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;

        RETURN NEW;
        END;
        $$;

        CREATE TRIGGER auto_maintain_user_topic
        AFTER INSERT OR UPDATE OF "primary", linked, archived_at ON public.user_contact
        FOR EACH ROW
        EXECUTE FUNCTION public.auto_maintain_user_topic ();

        -- Auto-create and maintain twist-admin topics.
        CREATE OR REPLACE FUNCTION public.auto_maintain_twist_admin_topic ()
        RETURNS TRIGGER
        LANGUAGE plpgsql
        AS $$
        DECLARE
        v_topic_id uuid;
        v_contact_id uuid;
        BEGIN
        SELECT id INTO v_topic_id FROM topic WHERE auto_twist_admin_id = COALESCE(NEW.id, OLD.id);
        IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, auto_twist_admin_id, created_by, auto_maintained)
        VALUES ('Twist Admins', 'private', NEW.id, COALESCE(NEW.user_id, (SELECT id FROM "user" LIMIT 1)), TRUE)
        RETURNING id INTO v_topic_id;
        END IF;

        IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
        END IF;

        IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        IF NEW.user_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
            END IF;
            INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;
        END IF;
        -- Handle publisher_id if needed, but for now we focus on user_id
        ELSIF TG_OP = 'DELETE' THEN
        -- Cascades take care of it
        END IF;

        RETURN COALESCE(NEW, OLD);
        END;
        $$;

        CREATE TRIGGER auto_maintain_twist_admin_topic
        AFTER INSERT OR DELETE OR UPDATE OF user_id, publisher_id ON public.twist_admin
        FOR EACH ROW
        EXECUTE FUNCTION public.auto_maintain_twist_admin_topic ();


-- Auto-add new users to the "Everyone" topic.
CREATE OR REPLACE FUNCTION public.auto_maintain_everyone_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_everyone_topic_id uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.linked = TRUE AND NEW."primary" = TRUE THEN
        SELECT id INTO v_everyone_topic_id
        FROM topic
        WHERE auto_maintained = TRUE AND team_id IS NULL;

        IF v_everyone_topic_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id)
            VALUES (v_everyone_topic_id, NEW.contact_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
        NEW.linked = FALSE OR NEW."primary" = FALSE OR NEW.archived_at IS NOT NULL
    )) THEN
        SELECT id INTO v_everyone_topic_id
        FROM topic
        WHERE auto_maintained = TRUE AND team_id IS NULL;

        IF v_everyone_topic_id IS NOT NULL THEN
            DELETE FROM topic_member
            WHERE topic_id = v_everyone_topic_id
              AND contact_id = COALESCE(OLD.contact_id, NEW.contact_id);
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_everyone_topic
    AFTER INSERT OR UPDATE OR DELETE ON public.user_contact
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_everyone_topic ();
