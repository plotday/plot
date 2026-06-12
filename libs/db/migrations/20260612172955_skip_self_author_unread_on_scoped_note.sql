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
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq);
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
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   now()
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
            SET bumped_at = now(),
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
