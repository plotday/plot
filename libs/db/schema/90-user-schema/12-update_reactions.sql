-- RPCs for the emoji-reaction tables (note_reaction, thread_reaction).
--
-- Reactions follow the same only-self ownership rule as count tags
-- (see libs/db/AGENTS.md "Count Tag Ownership"): a user can only add
-- or remove their own reactions, and linked-contact siblings count as
-- self. There is no cross-user targeting, no compute/toggle/count
-- discriminator, and no reply-tag propagation — that lives on tag_id
-- 1019 in note_tag / thread_tag until clients fully migrate.

CREATE OR REPLACE FUNCTION "user".upsert_note_reaction (
    user_id uuid,
    p_actor_id uuid,
    p_note_id uuid,
    p_emoji text,
    p_updated_by integer DEFAULT 0,
    p_archived_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS note_reaction
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row note_reaction;
BEGIN
    IF p_emoji IS NULL OR p_emoji = '' THEN
        RAISE EXCEPTION 'p_emoji must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = upsert_note_reaction.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    -- Linked contacts are equivalent identities. The actor must overlap
    -- the caller's sibling set; we always write against the canonical
    -- (primary) contact id so the live row tracks the user's current
    -- primary contact.
    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    -- Collapse any sibling-aliased live rows to the canonical primary id.
    -- Matches the equivalent upsert_note_tag step.
    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE note_reaction
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE note_id = p_note_id
          AND emoji = p_emoji
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO note_reaction (actor_id, note_id, emoji, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_note_id, p_emoji, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, emoji)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;


CREATE OR REPLACE FUNCTION "user".upsert_thread_reaction (
    user_id uuid,
    p_actor_id uuid,
    p_thread_id uuid,
    p_emoji text,
    p_occurrence text DEFAULT NULL::text,
    p_updated_by integer DEFAULT 0,
    p_archived_at timestamptz DEFAULT NULL::timestamptz
)
    RETURNS thread_reaction
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_row thread_reaction;
BEGIN
    IF p_emoji IS NULL OR p_emoji = '' THEN
        RAISE EXCEPTION 'p_emoji must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_reaction.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    IF p_archived_at IS NULL AND array_length(v_actor_sibling_ids, 1) > 1 THEN
        UPDATE thread_reaction
        SET archived_at = now(),
            updated_by = COALESCE(p_updated_by, 0)
        WHERE thread_id = p_thread_id
          AND emoji = p_emoji
          AND (occurrence IS NOT DISTINCT FROM p_occurrence)
          AND actor_id = ANY(v_actor_sibling_ids)
          AND actor_id != v_canonical_actor_id
          AND archived_at IS NULL;
    END IF;

    INSERT INTO thread_reaction (actor_id, thread_id, occurrence, emoji, updated_by, archived_at)
        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, p_emoji, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, thread_id, occurrence, emoji)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$function$;


-- Batch update note reactions for a single (note, actor). p_reaction_updates
-- is a JSON object: { "<emoji>": true | false, ... }. Mirrors the shape of
-- update_note_tags but keyed by emoji string rather than tag_id integer.
CREATE OR REPLACE FUNCTION "user".update_note_reactions (
    user_id uuid,
    p_note_id uuid,
    p_actor_id uuid,
    p_client_id integer,
    p_reaction_updates jsonb
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    rec record;
    v_emoji text;
    is_adding boolean;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_priority_id uuid;
BEGIN
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        note n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
            AND tp.user_id = update_note_reactions.user_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM note WHERE id = p_note_id) THEN
            RAISE EXCEPTION 'Note not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    FOR rec IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_reaction_updates)
        LOOP
            v_emoji := rec.key;
            is_adding := rec.value::boolean;
            IF v_emoji IS NULL OR v_emoji = '' THEN
                RAISE EXCEPTION 'Reaction emoji must be a non-empty string';
            END IF;

            IF is_adding THEN
                -- Only insert when no live row exists for any of the
                -- actor's linked-contact siblings; always write canonical.
                IF NOT EXISTS (
                    SELECT 1 FROM note_reaction
                    WHERE note_id = p_note_id
                      AND emoji = v_emoji
                      AND actor_id = ANY(v_actor_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO note_reaction (actor_id, note_id, emoji, updated_at, archived_at, updated_by)
                        VALUES (v_canonical_actor_id, p_note_id, v_emoji, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, note_id, emoji)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
            ELSE
                -- Clearing one alias clears every linked-contact sibling's row.
                UPDATE note_reaction
                SET archived_at = now(),
                    updated_by = p_client_id
                WHERE note_id = p_note_id
                  AND emoji = v_emoji
                  AND actor_id = ANY(v_actor_sibling_ids)
                  AND archived_at IS NULL;
            END IF;
        END LOOP;
END;
$function$;


CREATE OR REPLACE FUNCTION "user".update_thread_reactions (
    user_id uuid,
    p_thread_id uuid,
    p_actor_id uuid,
    p_client_id integer,
    p_reaction_updates jsonb,
    p_occurrence text DEFAULT NULL::text
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
DECLARE
    rec record;
    v_emoji text;
    is_adding boolean;
    v_canonical_actor_id uuid;
    v_actor_sibling_ids uuid[];
    v_caller_sibling_ids uuid[];
    v_priority_id uuid;
BEGIN
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = update_thread_reactions.user_id;
    IF v_priority_id IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = p_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_canonical_actor_id := "user".canonical_contact_id(p_actor_id);
    v_actor_sibling_ids := "user".sibling_contact_ids(p_actor_id);
    v_caller_sibling_ids := "user".user_contact_ids(user_id);
    IF NOT (v_actor_sibling_ids && v_caller_sibling_ids) THEN
        RAISE EXCEPTION 'Cannot modify reactions for other users';
    END IF;

    FOR rec IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_reaction_updates)
        LOOP
            v_emoji := rec.key;
            is_adding := rec.value::boolean;
            IF v_emoji IS NULL OR v_emoji = '' THEN
                RAISE EXCEPTION 'Reaction emoji must be a non-empty string';
            END IF;

            IF is_adding THEN
                IF NOT EXISTS (
                    SELECT 1 FROM thread_reaction
                    WHERE thread_id = p_thread_id
                      AND emoji = v_emoji
                      AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                      AND actor_id = ANY(v_actor_sibling_ids)
                      AND archived_at IS NULL
                ) THEN
                    INSERT INTO thread_reaction (actor_id, thread_id, occurrence, emoji, updated_at, archived_at, updated_by)
                        VALUES (v_canonical_actor_id, p_thread_id, p_occurrence, v_emoji, now(), NULL, p_client_id)
                    ON CONFLICT (actor_id, thread_id, occurrence, emoji)
                        DO UPDATE SET
                            archived_at = NULL,
                            updated_at = now(),
                            updated_by = p_client_id;
                END IF;
            ELSE
                UPDATE thread_reaction
                SET archived_at = now(),
                    updated_by = p_client_id
                WHERE thread_id = p_thread_id
                  AND emoji = v_emoji
                  AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                  AND actor_id = ANY(v_actor_sibling_ids)
                  AND archived_at IS NULL;
            END IF;
        END LOOP;
END;
$function$;
