-- Create "protect_note_author" function
CREATE FUNCTION "public"."protect_note_author" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- author_id is immutable: always preserve original value
    NEW.author_id := OLD.author_id;
    -- Un-archiving: allow created_by update (for twist re-sync)
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        RETURN NEW;
    END IF;
    -- Otherwise: prevent created_by changes
    NEW.created_by := OLD.created_by;
    RETURN NEW;
END;
$$;
-- Create trigger "protect_note_author_trigger"
CREATE TRIGGER "protect_note_author_trigger" BEFORE UPDATE ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."protect_note_author"();
-- Modify "protect_activity_created_by" function
CREATE OR REPLACE FUNCTION "public"."protect_activity_created_by" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- author_id is immutable: always preserve original value
    NEW.author_id := OLD.author_id;
    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            -- Derive created_by_twist_id from new created_by
            SELECT
                pt.twist_id INTO NEW.created_by_twist_id
            FROM
                priority_twist pt
            WHERE
                pt.id = NEW.created_by;
        END IF;
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
        NEW.created_by_twist_id := OLD.created_by_twist_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_activity_id" uuid, "p_draft" boolean, "p_private" boolean, "p_content" text, "p_links" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (activity_id, key)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
