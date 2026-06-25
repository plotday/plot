-- Modify "fanout_activity_at_to_thread_priority" function
CREATE OR REPLACE FUNCTION "public"."fanout_activity_at_to_thread_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE thread_priority tp
    SET activity_at = v.new_at
    FROM (
        SELECT tp2.user_id,
               COALESCE(GREATEST(NEW.activity_base, ts.bumped_at), NEW.created_at) AS new_at
        FROM thread_priority tp2
        LEFT JOIN thread_state ts
               ON ts.thread_id = tp2.thread_id AND ts.user_id = tp2.user_id
        WHERE tp2.thread_id = NEW.id
    ) v
    WHERE tp.thread_id = NEW.id
      AND tp.user_id = v.user_id
      AND tp.activity_at IS DISTINCT FROM v.new_at;
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NULL;
END;
$$;
-- Modify "seed_thread_priority_activity_at" function
CREATE OR REPLACE FUNCTION "public"."seed_thread_priority_activity_at" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.activity_at IS NULL THEN
        SELECT COALESCE(
                   GREATEST(a.activity_base, ts.bumped_at),
                   a.created_at)
          INTO NEW.activity_at
          FROM thread a
          LEFT JOIN thread_state ts
                 ON ts.thread_id = a.id AND ts.user_id = NEW.user_id
         WHERE a.id = NEW.thread_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "update_thread_activity_from_link" function
CREATE OR REPLACE FUNCTION "public"."update_thread_activity_from_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    IF NEW.thread_id IS NOT NULL AND NEW.source_created_at IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        -- activity_base is the max of CONTENT source times only — never seeded
        -- with created_at (import time). GREATEST() ignores a NULL activity_base,
        -- so the first link sets it to source_created_at even when that predates
        -- the thread's import. The created_at fallback happens at read time in
        -- thread_priority.activity_at, so backfilled content sorts by its origin.
        UPDATE thread
        SET activity_base = GREATEST(activity_base, NEW.source_created_at)
        WHERE id = NEW.thread_id
          AND (activity_base IS NULL OR activity_base < NEW.source_created_at);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "update_thread_activity_from_schedule" function
CREATE OR REPLACE FUNCTION "public"."update_thread_activity_from_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_thread_id uuid;
    v_end       timestamptz;
BEGIN
    IF NEW.occurrence IS NOT NULL OR NEW.recurrence_rule IS NOT NULL
       OR NEW.archived_at IS NOT NULL THEN
        RETURN NEW;
    END IF;
    v_end := COALESCE(upper(NEW.at), upper(NEW."on")::timestamptz);
    IF v_end IS NULL OR v_end > now() THEN
        RETURN NEW;  -- unbounded or future: client owns ordering
    END IF;
    v_thread_id := NEW.thread_id;
    IF v_thread_id IS NULL AND NEW.link_id IS NOT NULL THEN
        SELECT l.thread_id INTO v_thread_id FROM link l WHERE l.id = NEW.link_id;
    END IF;
    IF v_thread_id IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    -- Max of CONTENT times only — never seeded with created_at (import time).
    -- GREATEST() ignores a NULL activity_base.
    UPDATE thread
    SET activity_base = GREATEST(activity_base, v_end)
    WHERE id = v_thread_id
      AND (activity_base IS NULL OR activity_base < v_end);
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NEW;
END;
$$;
-- Modify "update_thread_on_note_change" function
CREATE OR REPLACE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- Only act on visible, non-draft notes.
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        IF NEW.access_contacts IS NULL AND NEW.access_groups IS NULL THEN
            -- UNSCOPED note: everyone who can see the thread can see it.
            -- Bump the shared last_note_* columns exactly as before so the
            -- thread re-emits / re-sorts for all recipients.
            UPDATE thread
            SET last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
                last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
                last_note_seq = GREATEST (last_note_seq, NEW.seq),
                -- Max of CONTENT source times only — never seeded with created_at
                -- (import time), so a backfilled note keeps the thread at its
                -- origin time. GREATEST() ignores a NULL activity_base.
                activity_base = GREATEST (activity_base, NEW.source_created_at),
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq
                  OR activity_base IS NULL
                  OR activity_base < NEW.source_created_at);
        ELSE
            -- SCOPED note: do NOT touch the shared last_note_* columns (that
            -- would re-emit the thread for the whole audience, leaking the
            -- existence of a private reply). Instead bump thread_state for
            -- exactly the users who can see this note, so the thread
            -- re-emits / re-sorts / unreads only for them. The author's row
            -- is bumped but kept read; other visible users get read_at = NULL.
            --
            -- "The author" is identified by NEW.author_id (the contact credited
            -- with the note), resolved to its owning user, NOT only by
            -- NEW.created_by. For a reply the user made OUTSIDE Plot (e.g. in
            -- Gmail) and a connector synced back, created_by is the connector's
            -- twist_instance_id while author_id is the user's own linked
            -- contact — so a created_by-only check would mark the author unread
            -- and notify them about their own reply.
            --
            -- bumped_at carries the note's ORIGIN time (source_created_at), NOT
            -- now(). It is the only per-user input to thread_priority.activity_at,
            -- so a live reply (source ~ now) re-surfaces the thread while a
            -- backfilled historical reply sorts at its true time instead of
            -- masquerading as fresh activity at import. The app's separate
            -- Active→Done write sets bumped_at = now() directly; the ON CONFLICT
            -- GREATEST below never lowers such a bump.
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at, last_note_source_created_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   NEW.source_created_at,
                   NEW.source_created_at
            FROM (
                SELECT tp.user_id
                FROM thread_priority tp
                WHERE tp.thread_id = NEW.thread_id
                  AND tp.revoked_at IS NULL
                  AND (
                      tp.user_id = NEW.created_by
                      OR (NEW.access_contacts IS NOT NULL
                          AND NEW.access_contacts && "user".user_contact_ids(tp.user_id))
                      OR (NEW.access_groups IS NOT NULL
                          AND NEW.access_groups && "user".user_group_ids(tp.user_id))
                  )
            ) v
            ON CONFLICT (user_id, thread_id) DO UPDATE
            -- Raise to the note's origin time, never lower an existing (newer)
            -- value — preserves an app-set Active→Done bump and orders by the
            -- latest message this user can actually see.
            SET bumped_at = GREATEST(thread_state.bumped_at, NEW.source_created_at),
                last_note_source_created_at =
                    GREATEST(thread_state.last_note_source_created_at, NEW.source_created_at),
                -- A non-author visible user must see the thread as unread
                -- again; never clobber the author's own read state. The author
                -- is matched by NEW.author_id (its owning user) as well as by
                -- created_by, so a reply synced back from an external system
                -- (created_by = connector, author_id = the user's contact)
                -- does not re-surface as unread for its own author.
                read_at = CASE
                    WHEN thread_state.user_id = NEW.created_by
                         OR NEW.author_id = ANY("user".user_contact_ids(thread_state.user_id))
                    THEN thread_state.read_at
                    ELSE NULL
                END,
                updated_at = now();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Modify "update_tp_activity_from_thread_state" function
CREATE OR REPLACE FUNCTION "public"."update_tp_activity_from_thread_state" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE thread_priority tp
    SET activity_at = COALESCE(GREATEST(a.activity_base, NEW.bumped_at), a.created_at)
    FROM thread a
    WHERE tp.thread_id = NEW.thread_id
      AND tp.user_id = NEW.user_id
      AND a.id = tp.thread_id
      AND tp.activity_at IS DISTINCT FROM COALESCE(GREATEST(a.activity_base, NEW.bumped_at), a.created_at);
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    RETURN NULL;
END;
$$;
