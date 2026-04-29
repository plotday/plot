-- Modify "channel" table
ALTER TABLE "public"."channel" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_channel_seq" to table: "channel"
CREATE INDEX "idx_channel_seq" ON "public"."channel" ("seq");
-- Create "update_seq_and_updated_at" function
CREATE FUNCTION "public"."update_seq_and_updated_at" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    NEW.seq = pg_current_xact_id();
    RETURN NEW;
END;
$$;
-- Modify "set_channel_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_channel_updated_at" BEFORE INSERT OR UPDATE ON "public"."channel" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "schedule" view
DROP VIEW "user"."schedule";
-- Drop "twist_instance_note_update" view
DROP VIEW "public"."twist_instance_note_update";
-- Drop "actor" view
DROP VIEW "user"."actor";
-- Drop "twist_instance_channel_note_create" view
DROP VIEW "public"."twist_instance_channel_note_create";
-- Drop "twist_instance_channel_link_create" view
DROP VIEW "public"."twist_instance_channel_link_create";
-- Drop "twist_instance_channel_link_update" view
DROP VIEW "public"."twist_instance_channel_link_update";
-- Drop "twist_instance_link_update" view
DROP VIEW "public"."twist_instance_link_update";
-- Drop "twist_instance_note_create" view
DROP VIEW "public"."twist_instance_note_create";
-- Drop "actor" view
DROP VIEW "public"."actor";
-- Modify "contact" table
ALTER TABLE "public"."contact" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_contact_seq" to table: "contact"
CREATE INDEX "idx_contact_seq" ON "public"."contact" ("seq");
-- Modify "set_contact_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "group" view
DROP VIEW "user"."group";
-- Modify "group" table
ALTER TABLE "public"."group" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_group_seq" to table: "group"
CREATE INDEX "idx_group_seq" ON "public"."group" ("seq");
-- Modify "set_group_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_group_updated_at" BEFORE INSERT OR UPDATE ON "public"."group" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "link" view
DROP VIEW "user"."link";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Modify "link" table
ALTER TABLE "public"."link" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_link_seq" to table: "link"
CREATE INDEX "idx_link_seq" ON "public"."link" ("seq");
-- Modify "set_link_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_link_updated_at" BEFORE INSERT OR UPDATE ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "note_redacted" view
DROP VIEW "user"."note_redacted";
-- Drop "note" view
DROP VIEW "user"."note";
-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_note_seq" to table: "note"
CREATE INDEX "idx_note_seq" ON "public"."note" ("seq");
-- Modify "set_note_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_note_updated_at" BEFORE INSERT OR UPDATE ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "note_tags" view
DROP VIEW "public"."note_tags";
-- Modify "note_tag" table
ALTER TABLE "public"."note_tag" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_note_tag_seq" to table: "note_tag"
CREATE INDEX "idx_note_tag_seq" ON "public"."note_tag" ("seq");
-- Modify "set_note_tag_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_note_tag_updated_at" BEFORE INSERT OR UPDATE ON "public"."note_tag" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "priority" view
DROP VIEW "user"."priority" CASCADE;
-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_priority_seq" to table: "priority"
CREATE INDEX "idx_priority_seq" ON "public"."priority" ("seq");
-- Modify "set_priority_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_priority_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "schedule" table
ALTER TABLE "public"."schedule" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_schedule_seq" to table: "schedule"
CREATE INDEX "idx_schedule_seq" ON "public"."schedule" ("seq");
-- Modify "set_schedule_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_schedule_updated_at" BEFORE INSERT OR UPDATE ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "schedule_contact" table
ALTER TABLE "public"."schedule_contact" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_schedule_contact_seq" to table: "schedule_contact"
CREATE INDEX "idx_schedule_contact_seq" ON "public"."schedule_contact" ("seq");
-- Modify "set_schedule_contact_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_schedule_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."schedule_contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "session" table
ALTER TABLE "public"."session" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_session_seq" to table: "session"
CREATE INDEX "idx_session_seq" ON "public"."session" ("seq");
-- Modify "set_session_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_session_updated_at" BEFORE INSERT OR UPDATE ON "public"."session" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(), ADD COLUMN "last_note_seq" xid8 NOT NULL DEFAULT '0'::xid8;
-- Create index "idx_thread_seq" to table: "thread"
CREATE INDEX "idx_thread_seq" ON "public"."thread" ("seq");
-- Modify "set_thread_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "thread_association" view
DROP VIEW "user"."thread_association";
-- Modify "thread_association" table
ALTER TABLE "public"."thread_association" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_thread_association_seq" to table: "thread_association"
CREATE INDEX "idx_thread_association_seq" ON "public"."thread_association" ("seq");
-- Modify "set_thread_association_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_association_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_association" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "thread_priority" table
ALTER TABLE "public"."thread_priority" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_thread_priority_seq" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_seq" ON "public"."thread_priority" ("seq");
-- Modify "set_thread_priority_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_priority_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "thread_read" table
ALTER TABLE "public"."thread_read" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_thread_read_seq" to table: "thread_read"
CREATE INDEX "idx_thread_read_seq" ON "public"."thread_read" ("seq");
-- Modify "set_thread_read_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_read_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_read" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "thread_tag" table
ALTER TABLE "public"."thread_tag" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_thread_tag_seq" to table: "thread_tag"
CREATE INDEX "idx_thread_tag_seq" ON "public"."thread_tag" ("seq");
-- Modify "set_thread_tag_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_tag_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_tag" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "thread_unread" table
ALTER TABLE "public"."thread_unread" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_thread_unread_seq" to table: "thread_unread"
CREATE INDEX "idx_thread_unread_seq" ON "public"."thread_unread" ("seq");
-- Modify "set_thread_unread_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_thread_unread_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_unread" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Drop "twist_instance_details" view
DROP VIEW "public"."twist_instance_details";
-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_twist_instance_seq" to table: "twist_instance"
CREATE INDEX "idx_twist_instance_seq" ON "public"."twist_instance" ("seq");
-- Modify "set_twist_instance_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_twist_instance_updated_at" BEFORE INSERT OR UPDATE ON "public"."twist_instance" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "twist_instance_connection" table
ALTER TABLE "public"."twist_instance_connection" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_twist_instance_connection_seq" to table: "twist_instance_connection"
CREATE INDEX "idx_twist_instance_connection_seq" ON "public"."twist_instance_connection" ("seq");
-- Create "update_seq" function
CREATE FUNCTION "public"."update_seq" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.seq = pg_current_xact_id();
    RETURN NEW;
END;
$$;
-- Create trigger "set_twist_instance_connection_seq"
CREATE TRIGGER "set_twist_instance_connection_seq" BEFORE UPDATE ON "public"."twist_instance_connection" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq"();
-- Modify "user_contact" table
ALTER TABLE "public"."user_contact" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_user_contact_seq" to table: "user_contact"
CREATE INDEX "idx_user_contact_seq" ON "public"."user_contact" ("seq");
-- Modify "set_user_contact_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_user_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."user_contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_user_settings_seq" to table: "user_settings"
CREATE INDEX "idx_user_settings_seq" ON "public"."user_settings" ("seq");
-- Modify "set_user_settings_updated_at" trigger
CREATE OR REPLACE TRIGGER "set_user_settings_updated_at" BEFORE INSERT OR UPDATE ON "public"."user_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Modify "user_sync" table
ALTER TABLE "public"."user_sync" ADD COLUMN "last_update_seq" xid8 NOT NULL DEFAULT '0'::xid8, ADD COLUMN "last_sync_seq" xid8 NOT NULL DEFAULT '0'::xid8;
-- Create index "idx_user_sync_pending_seq" to table: "user_sync"
CREATE INDEX "idx_user_sync_pending_seq" ON "public"."user_sync" ("user_id") WHERE (last_update_seq > last_sync_seq);
-- Modify "sync_user_for_channel" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_channel" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify the owner of the source account
    FOR v_user_id IN SELECT DISTINCT
        pt.owner_id
    FROM
        new_table n
        JOIN twist_instance pt ON pt.id = n.twist_instance_id
    ORDER BY
        pt.owner_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'channel', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_contact" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Contact changes affect all users who have visibility of this contact via user_contact
    FOR v_user_id IN SELECT DISTINCT
        uc.user_id
    FROM
        new_table n
        JOIN user_contact uc ON uc.contact_id = n.id
    WHERE
        uc.archived_at IS NULL
    ORDER BY
        uc.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'actor', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_group" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_group" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_user_id IN SELECT DISTINCT
        ug.user_id
    FROM
        new_table n
        JOIN "user"."group" ug ON ug.id = n.id
    ORDER BY
        ug.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'group', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the link's thread filed via thread_priority,
    -- or who own the link's direct priority (for threadless links)
    FOR v_user_id IN SELECT DISTINCT
        COALESCE(tp.user_id, p.user_id) AS user_id
    FROM
        new_table n
        LEFT JOIN thread_priority tp ON tp.thread_id = n.thread_id
        LEFT JOIN priority p ON p.id = n.priority_id AND n.thread_id IS NULL
    WHERE
        tp.user_id IS NOT NULL OR p.user_id IS NOT NULL
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'note', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread_priority tp ON tp.thread_id = nt.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'note', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_priority" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users with access to the priority (including hierarchical access via ancestors)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'priority', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_schedule" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the schedule's thread filed via thread_priority
    -- Handles both direct thread_id and link schedules (via link → thread)
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        LEFT JOIN link l ON l.id = n.link_id
        JOIN thread_priority tp ON tp.thread_id = COALESCE(n.thread_id, l.thread_id)
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'schedule', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    -- Also notify per-user schedule owners directly
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        n.user_id IS NOT NULL
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'schedule', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_session" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_session" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Only notify the session owner
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'session', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have this thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.id
    ORDER BY
        tp.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread_priority" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Fall back to now() for DELETE (which has no updated_at column).
    IF v_max_updated_at IS NULL THEN
        v_max_updated_at := now();
    END IF;
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread_read" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_read" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Only notify the reading user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread_read', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = a.id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_thread_unread" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_unread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Only notify the affected user (the one marked as unread)
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread_read', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_twist_instance" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_twist_instance" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify the owner of each twist_instance
    FOR v_user_id IN SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_instance', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_twist_instance_connection" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_twist_instance_connection" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Use the most recent lifecycle stamp on each row -- this matches the
    -- `updated_at` projected by the user.twist_connection view so client
    -- incremental cursors line up.
    SELECT
        MAX(GREATEST(
            connected_at,
            needs_reauth_at,
            initial_sync_started_at,
            initial_sync_completed_at
        )),
        MAX(seq)
    INTO v_max_at, v_max_seq
    FROM
        new_table;
    -- Fall back to now() for DELETE (transition table values are deleted rows).
    IF v_max_at IS NULL THEN
        v_max_at := now();
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify each affected user directly. Bump both `twist_instance` (legacy
    -- consumer; user.twist surfaces user_connected) and `twist_connection`
    -- (new entity for needs_reauth / initial_syncing signals).
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_instance', v_max_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_connection', v_max_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_on_connect" function
CREATE OR REPLACE FUNCTION "public"."sync_user_on_connect" ("p_user_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- Update all user_sync rows for this user. Set both watermarks
    -- (timestamp + seq) to match their respective `last_update_*` since the
    -- client has full data after the connect-time pull. Both columns are
    -- maintained during the expand-contract rollout; readers may consult
    -- either or both.
    UPDATE
        user_sync
    SET
        last_sync_at = last_update_at,
        last_sync_seq = last_update_seq
    WHERE
        user_id = p_user_id;
END;
$$;
-- Modify "update_thread_on_note_change" function
CREATE OR REPLACE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the thread read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this thread to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        -- Update thread's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        -- last_note_seq is the sync-cursor counterpart of last_note_created_at:
        -- the user.thread view exposes GREATEST(thread.seq, last_note_seq, ...)
        -- so a new note advances /sync/threads' cursor for the parent thread.
        UPDATE
            thread
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            last_note_seq = GREATEST (last_note_seq, NEW.seq),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.thread_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at
                OR last_note_seq < NEW.seq);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Drop "get_pending_user_sync" function
DROP FUNCTION "public"."get_pending_user_sync";
-- Create "get_pending_user_sync" function
CREATE FUNCTION "public"."get_pending_user_sync" ("p_user_id" uuid) RETURNS TABLE ("entity" text, "last_update_at" timestamptz, "last_update_seq" xid8) LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT
        entity,
        last_update_at,
        last_update_seq
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND (last_update_at > last_sync_at OR last_update_seq > last_sync_seq);
$$;
-- Create "twist_instance_details" view
CREATE VIEW "public"."twist_instance_details" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "seq",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url"
) AS SELECT pt.id,
    pt.twist_id,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    pt.seq,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     LEFT JOIN public.publisher p ON t.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.twist_instance_details tid ON tid.id = a.created_by
  WHERE a.draft = false;
-- Create "thread_association" view
CREATE VIEW "user"."thread_association" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "parent_thread_id",
  "child_thread_id",
  "order"
) AS SELECT tp.user_id,
    ta.id,
    ta.created_at,
    ta.updated_at,
    ta.seq,
    ta.archived_at,
    ta.parent_thread_id,
    ta.child_thread_id,
    ta."order"
   FROM public.thread_association ta
     JOIN public.thread_priority tp ON tp.thread_id = ta.parent_thread_id;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "has_embedding",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(tu.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.embedding IS NOT NULL AS has_embedding,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    tt.seq,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                    max(at.seq) AS seq
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Create "group" view
CREATE VIEW "user"."group" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "name",
  "type",
  "join_policy",
  "team_id",
  "auto_maintained",
  "is_admin",
  "is_member",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.seq,
    g.archived_at,
    g.name,
    g.type,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) AS is_admin,
    (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS is_member,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.group_admin ga
              WHERE ga.group_id = g.id AND ga.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            WHEN (g.type = ANY (ARRAY['private'::public.group_type, 'team'::public.group_type])) AND (EXISTS ( SELECT 1
               FROM public.group_member gm
                 JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
              WHERE gm.group_id = g.id AND uc.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public."group" g
  WHERE g.archived_at IS NULL AND ((g.type = ANY (ARRAY['public'::public.group_type, 'announce'::public.group_type])) OR g.key = '@plot.team'::text OR g.type = 'team'::public.group_type AND (EXISTS ( SELECT 1
           FROM public.team_user tu
          WHERE tu.team_id = g.team_id AND tu.user_id = u.id)) OR g.type = 'private'::public.group_type AND ((EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id))));
-- Create "note_tags" view
CREATE VIEW "public"."note_tags" (
  "note_id",
  "tags",
  "updated_at",
  "seq",
  "updated_by"
) AS SELECT note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    max(seq) AS seq,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT nt.note_id,
            nt.tag_id,
            jsonb_agg(nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
            max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
            max(nt.seq) AS seq,
            (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
           FROM public.note_tag nt
          GROUP BY nt.note_id, nt.tag_id) sq
  GROUP BY note_id;
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "priority" view
CREATE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread",
  "role",
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set",
  "inherit_members",
  "config",
  "default_contacts",
  "default_groups",
  "default_invite_emails"
) AS WITH user_root AS (
         SELECT DISTINCT ON (p_1.user_id) p_1.user_id,
            p_1.id AS root_id,
            p_1.path AS root_path
           FROM public.priority p_1
          WHERE public.nlevel(p_1.path) = 1
          ORDER BY p_1.user_id, p_1.created_at
        ), direct_settings AS (
         SELECT priority_setting.user_id,
            priority_setting.priority_id,
            max(
                CASE
                    WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS top_order,
            max(
                CASE
                    WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                    ELSE NULL::double precision
                END) AS "order",
            max(
                CASE
                    WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                    ELSE NULL::text
                END) AS title,
            max(
                CASE
                    WHEN priority_setting.key = 'attention_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS attention_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_requests'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_requests_set,
            max(
                CASE
                    WHEN priority_setting.key = 'see_within_updates'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS see_within_updates_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id
        ), inherited_settings AS (
         SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'color'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'attention_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS attention_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_requests'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_requests,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within_updates'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within_updates,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.seq,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    inh.color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.attention_window,
    inh.see_within_requests,
    inh.see_within_updates,
    COALESCE(direct.attention_window_set, false) AS attention_window_set,
    COALESCE(direct.see_within_requests_set, false) AS see_within_requests_set,
    COALESCE(direct.see_within_updates_set, false) AS see_within_updates_set,
    p.inherit_members,
    p.config,
    p.default_contacts,
    p.default_groups,
    p.default_invite_emails
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;
-- Create "schedule" view
CREATE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    GREATEST(s.seq, COALESCE(( SELECT max(sc.seq) AS max
           FROM public.schedule_contact sc
          WHERE sc.schedule_id = s.id), '0'::xid8)) AS seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    s.outstanding_tasks,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
  WHERE s.user_id IS NULL OR s.user_id = tp.user_id;
-- Create "actor" view
CREATE VIEW "public"."actor" (
  "id",
  "created_at",
  "updated_at",
  "seq",
  "type",
  "name",
  "email",
  "avatar_url",
  "archived_at",
  "inviteable"
) AS SELECT c.id,
    c.created_at,
    c.updated_at,
    c.seq,
        CASE
            WHEN c.user_id IS NOT NULL THEN 'user'::text
            ELSE 'contact'::text
        END AS type,
    c.name,
    c.email,
    c.avatar_url,
    c.archived_at,
    c.inviteable
   FROM public.contact c
UNION ALL
 SELECT pt.id,
    pt.created_at,
    pt.updated_at,
    pt.seq,
    'twist_instance'::text AS type,
        CASE
            WHEN pt.account_label IS NOT NULL AND pt.account_label <> ''::text THEN ((pt.name || ' ('::text) || pt.account_label) || ')'::text
            ELSE pt.name
        END AS name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at,
    true AS inviteable
   FROM public.twist_instance pt;
-- Create "twist_instance_note_update" view
CREATE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS twist_instance_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON n.created_by = pt.id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Create "note_redacted" view
CREATE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND n.access_contacts IS NOT NULL AND n.created_by <> tp.user_id AND NOT COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id);
-- Create "actor" view
CREATE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self",
  "inviteable",
  "primary",
  "linked_user_id"
) AS SELECT uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c_1
          WHERE c_1.id = a.id AND c_1.user_id = uc.user_id)) AS self,
    a.inviteable,
    true AS "primary",
    c.user_id AS linked_user_id
   FROM public.user_contact uc
     JOIN public.contact c ON c.id = uc.contact_id
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NULL OR c."primary" = true
UNION ALL
 SELECT uc_primary.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    c.user_id = uc_primary.user_id AS self,
    a.inviteable,
    false AS "primary",
    c.user_id AS linked_user_id
   FROM public.contact c
     JOIN public.actor a ON a.id = c.id
     JOIN public.contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
     JOIN public.user_contact uc_primary ON uc_primary.contact_id = c_primary.id
  WHERE c."primary" = false
UNION ALL
 SELECT u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id
   FROM public."user" u
     JOIN public.twist_instance pt ON pt.owner_id = u.id
     JOIN public.actor a ON a.id = pt.id;
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.access_contacts IS NULL OR n.created_by = tp.user_id OR n.access_contacts && "user".user_contact_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id));
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "twist_id",
  "twist_environment",
  "is_source",
  "multiple_instances",
  "shared",
  "key_option",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "options",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected",
  "is_builtin"
) AS SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    GREATEST(pt.seq, COALESCE(( SELECT max(ptc2.seq) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id), '0'::xid8)) AS seq,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = pt.owner_id))
        END AS user_connected,
    t.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f'::uuid AS is_builtin
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id;
-- Create "twist_instance_channel_note_create" view
CREATE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "link_id",
  "link_source",
  "link_title",
  "link_type",
  "link_meta",
  "link_channel_id",
  "link_source_url",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "author_name",
  "author_type",
  "tags"
) AS SELECT DISTINCT ON (ptc.twist_instance_id, n.id) ptc.twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    tp.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;
-- Create "twist_instance_channel_link_create" view
CREATE VIEW "public"."twist_instance_channel_link_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Create "twist_instance_channel_link_update" view
CREATE VIEW "public"."twist_instance_channel_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.twist_instance_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "twist_instance_link_update" view
CREATE VIEW "public"."twist_instance_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT l.created_by AS twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    tp.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance pt
     JOIN public.link l ON l.created_by = pt.id
     JOIN public.thread t ON t.id = l.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(pt.id) <> l.updated_by::numeric AND pt.archived_at IS NULL AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "link" view
CREATE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.logo,
    COALESCE(tp.priority_id, l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
   FROM public.link l
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;
-- Create "twist_instance_note_create" view
CREATE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
-- Modify "thread_x" view
CREATE OR REPLACE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "pending_contacts",
  "seq",
  "last_note_seq"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    groups,
    topic,
    embedding,
    twist_id,
    pending_contacts,
    seq,
    last_note_seq
   FROM public.thread a;
-- Modify "channel" view
CREATE OR REPLACE VIEW "user"."channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "enabled",
  "link_types",
  "default_priority_id",
  "default_priority_reason",
  "created_at",
  "updated_at",
  "seq"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.default_priority_id,
    sc.default_priority_reason,
    sc.created_at,
    sc.updated_at,
    sc.seq
   FROM public.channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
UNION
 SELECT DISTINCT tp.user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
    sc.default_priority_id,
    sc.default_priority_reason,
    sc.created_at,
    sc.updated_at,
    sc.seq
   FROM public.channel sc
     JOIN public.link l ON l.channel_id = sc.channel_id AND l.created_by = sc.twist_instance_id
     JOIN public.thread_priority tp ON tp.thread_id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id
  WHERE tp.user_id <> pt.owner_id;
-- Modify "twist_connection" view
CREATE OR REPLACE VIEW "user"."twist_connection" (
  "user_id",
  "twist_instance_id",
  "provider",
  "actor_id",
  "connected_at",
  "needs_reauth_at",
  "initial_sync_started_at",
  "initial_sync_completed_at",
  "needs_reauth",
  "initial_syncing",
  "updated_at",
  "seq"
) AS SELECT user_id,
    twist_instance_id,
    provider,
    actor_id,
    connected_at,
    needs_reauth_at,
    initial_sync_started_at,
    initial_sync_completed_at,
    needs_reauth_at IS NOT NULL AS needs_reauth,
    initial_sync_started_at IS NOT NULL AND initial_sync_completed_at IS NULL AS initial_syncing,
    GREATEST(connected_at, needs_reauth_at, initial_sync_started_at, initial_sync_completed_at) AS updated_at,
    seq
   FROM public.twist_instance_connection tic;
