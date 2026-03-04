-- Drop "thread_exception" view
DROP VIEW "user"."thread_exception";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Drop "priority_twist_thread_create" view
DROP VIEW "public"."priority_twist_thread_create";
-- Drop "priority_twist_thread_update" view
DROP VIEW "public"."priority_twist_thread_update";
-- Create "schedule" table (BEFORE dropping thread columns so we can migrate data)
CREATE TABLE "public"."schedule" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "user_id" uuid NULL,
  "order" double precision NULL DEFAULT public.order_first(),
  "at" tstzrange NULL,
  "on" daterange NULL,
  "recurrence_rule" text NULL,
  "duration" interval NULL,
  "recurrence_exdates" timestamp with time zone[] NULL,
  "occurrence" text NULL,
  "thread_id" uuid NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "schedule_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "schedule_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "schedule_at_xor_on" CHECK (((at IS NOT NULL) AND ("on" IS NULL)) OR ((at IS NULL) AND ("on" IS NOT NULL))),
  CONSTRAINT "schedule_order_user" CHECK (((user_id IS NULL) AND ("order" IS NULL)) OR ((user_id IS NOT NULL) AND ("order" IS NOT NULL))),
  CONSTRAINT "schedule_recurrence_duration" CHECK (((recurrence_rule IS NULL) AND (duration IS NULL)) OR ((recurrence_rule IS NOT NULL) AND (duration IS NOT NULL))),
  CONSTRAINT "schedule_recurrence_xor_occurrence" CHECK (NOT ((recurrence_rule IS NOT NULL) AND (occurrence IS NOT NULL)))
);
-- Create index "idx_schedule_at" to table: "schedule"
CREATE INDEX "idx_schedule_at" ON "public"."schedule" USING GIST ("at");
-- Create index "idx_schedule_on" to table: "schedule"
CREATE INDEX "idx_schedule_on" ON "public"."schedule" USING GIST ("on");
-- Create index "idx_schedule_thread_id" to table: "schedule"
CREATE INDEX "idx_schedule_thread_id" ON "public"."schedule" ("thread_id");
-- Create index "idx_schedule_updated_at" to table: "schedule"
CREATE INDEX "idx_schedule_updated_at" ON "public"."schedule" ("updated_at");
-- Create index "idx_schedule_user_id" to table: "schedule"
CREATE INDEX "idx_schedule_user_id" ON "public"."schedule" ("user_id") WHERE (user_id IS NOT NULL);
-- Create index "schedule_thread_occurrence_unique" to table: "schedule"
CREATE UNIQUE INDEX "schedule_thread_occurrence_unique" ON "public"."schedule" ("thread_id", "occurrence") WHERE (occurrence IS NOT NULL);
-- Create index "schedule_thread_user_unique" to table: "schedule"
CREATE UNIQUE INDEX "schedule_thread_user_unique" ON "public"."schedule" ("thread_id", "user_id") WHERE ((user_id IS NOT NULL) AND (occurrence IS NULL));
-- Create "sync_user_for_schedule" function
CREATE FUNCTION "public"."sync_user_for_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to affected thread's priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_schedule_insert"
CREATE TRIGGER "user_sync_schedule_insert" AFTER INSERT ON "public"."schedule" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_schedule"();
-- Create trigger "set_schedule_created_at"
CREATE TRIGGER "set_schedule_created_at" BEFORE INSERT ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_schedule_updated_at"
CREATE TRIGGER "set_schedule_updated_at" BEFORE INSERT OR UPDATE ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_schedule_update"
CREATE TRIGGER "user_sync_schedule_update" AFTER UPDATE ON "public"."schedule" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_schedule"();
-- Drop "set_thread_order_on_start_trigger" trigger
DROP TRIGGER "set_thread_order_on_start_trigger" ON "public"."thread";
-- ============================================================
-- DATA MIGRATION: Move scheduling data to new schedule table
-- Must happen before dropping thread_exception and thread_user_state tables
-- ============================================================

-- 1. Migrate thread scheduling → schedule (shared schedules)
-- Explicitly set user_id and order to NULL for shared schedules
-- Handle dirty data:
--   - schedule_recurrence_duration: recurrence_rule and duration must both be set or both NULL
--     When recurrence_rule exists without duration, derive duration from at/on range
--     When duration exists without recurrence_rule, clear duration
--   - schedule_at_xor_on: exactly one of at/on must be set; prefer at when both exist
INSERT INTO schedule (id, created_at, updated_at, archived_at, user_id, "order", "at", "on",
    recurrence_rule, duration, recurrence_exdates, thread_id)
SELECT uuidv7(), t.created_at, t.updated_at, NULL, NULL, NULL,
    CASE WHEN t.at IS NOT NULL THEN t.at ELSE NULL END,
    CASE WHEN t.at IS NOT NULL THEN NULL ELSE t."on" END,
    t.recurrence_rule,
    CASE
        WHEN t.recurrence_rule IS NOT NULL AND t.duration IS NULL THEN
            CASE
                WHEN t.at IS NOT NULL THEN upper(t.at) - lower(t.at)
                WHEN t."on" IS NOT NULL THEN (upper(t."on") - lower(t."on")) * INTERVAL '1 day'
                ELSE INTERVAL '1 hour'
            END
        WHEN t.recurrence_rule IS NULL AND t.duration IS NOT NULL THEN NULL
        ELSE t.duration
    END,
    CASE WHEN t.recurrence_rule IS NOT NULL THEN t.recurrence_exdates ELSE NULL END,
    t.id
FROM thread t
WHERE t.at IS NOT NULL OR t."on" IS NOT NULL;

-- 2. Migrate thread_exception → schedule (occurrence exceptions)
-- Inherit at/on from parent thread if exception doesn't have its own
INSERT INTO schedule (id, created_at, updated_at, archived_at, "at", "on",
    duration, occurrence, thread_id)
SELECT uuidv7(), te.created_at, te.updated_at, te.archived_at,
    COALESCE(te.at, t.at), COALESCE(te."on", t."on"),
    te.duration, te.occurrence, te.thread_id
FROM thread_exception te
JOIN thread t ON t.id = te.thread_id;

-- 3. Migrate thread_user_state → schedule (per-user schedules)
INSERT INTO schedule (id, created_at, updated_at, user_id, "order", "on", thread_id)
SELECT uuidv7(), tus.updated_at, tus.updated_at, tus.user_id, tus."order",
    tus."on", tus.thread_id
FROM thread_user_state tus;

-- ============================================================
-- END DATA MIGRATION
-- ============================================================

-- NOW drop scheduling columns from thread (data has been migrated)
ALTER TABLE "public"."thread" DROP CONSTRAINT "thread_action_assignee", DROP CONSTRAINT "thread_no_complete_recurrence", DROP CONSTRAINT "thread_recurrence_on_or_at", DROP CONSTRAINT "thread_scheduled", DROP CONSTRAINT "thread_single_schedule", DROP COLUMN "at", DROP COLUMN "on", DROP COLUMN "duration", DROP COLUMN "recurrence_rule", DROP COLUMN "recurrence_exdates";

-- Create "upsert_schedule" function
CREATE FUNCTION "user"."upsert_schedule" ("user_id" uuid, "p_schedule" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."schedule" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_thread_id uuid;
    v_priority_id uuid;
    v_schedule_user_id uuid;
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    v_result schedule;
BEGIN
    -- Extract fields
    v_id := COALESCE((p_schedule ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_schedule ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_schedule_user_id := COALESCE((p_schedule ->> 'user_id')::uuid, (p_defaults ->> 'user_id')::uuid);

    -- Resolve thread_id from existing schedule if updating
    IF v_thread_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            s.thread_id INTO v_thread_id
        FROM
            schedule s
        WHERE
            s.id = v_id;
    END IF;

    IF v_thread_id IS NULL THEN
        RAISE EXCEPTION 'thread_id must be provided';
    END IF;

    -- Look up priority for access check
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        thread a
    WHERE
        a.id = v_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    PERFORM "user".assert_priority_access(upsert_schedule.user_id, v_priority_id);

    -- Per-user schedules can only be created/modified by the owning user
    IF v_schedule_user_id IS NOT NULL AND v_schedule_user_id != upsert_schedule.user_id THEN
        RAISE EXCEPTION 'Cannot create/modify per-user schedule for another user';
    END IF;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Handle recurrence_exdates array conversion from JSONB
    IF p_schedule ? 'recurrence_exdates' AND jsonb_typeof(p_schedule -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;

    -- Handle add/remove exdates
    IF p_schedule ? 'recurrence_exdates_add' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_schedule ? 'recurrence_exdates_remove' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;

    -- Perform the upsert
    INSERT INTO schedule (id, thread_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, archived_at)
        VALUES (
            v_id,
            v_thread_id,
            v_schedule_user_id,
            CASE WHEN v_schedule_user_id IS NOT NULL THEN
                COALESCE((p_schedule ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first())
            ELSE
                NULL
            END,
            COALESCE((p_schedule ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange),
            COALESCE((p_schedule ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            COALESCE(p_schedule ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'),
            COALESCE((p_schedule ->> 'duration')::interval, (p_defaults ->> 'duration')::interval),
            v_recurrence_exdates,
            COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence'),
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            at = CASE WHEN p_schedule ? 'at' THEN
                (p_schedule ->> 'at')::tstzrange
            ELSE
                schedule.at
            END,
            "on" = CASE WHEN p_schedule ? 'on' THEN
                (p_schedule ->> 'on')::daterange
            ELSE
                schedule."on"
            END,
            recurrence_rule = CASE WHEN p_schedule ? 'recurrence_rule' THEN
                p_schedule ->> 'recurrence_rule'
            ELSE
                schedule.recurrence_rule
            END,
            duration = CASE WHEN p_schedule ? 'duration' THEN
                (p_schedule ->> 'duration')::interval
            ELSE
                schedule.duration
            END,
            recurrence_exdates = CASE WHEN p_schedule ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(schedule.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                schedule.recurrence_exdates
            END,
            "order" = CASE WHEN p_schedule ? 'order' THEN
                (p_schedule ->> 'order')::double precision
            ELSE
                schedule."order"
            END,
            archived_at = CASE WHEN p_schedule ? 'archived_at' THEN
                (p_schedule ->> 'archived_at')::timestamptz
            ELSE
                schedule.archived_at
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_type thread_type;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_created_by_twist_id bigint;
    v_assignee_id uuid;
    v_author_id uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_source := p_thread ->> 'source';
    v_type := COALESCE((p_thread ->> 'type')::thread_type, (p_defaults ->> 'type')::thread_type, 'note'::thread_type);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);
    END IF;
    -- DERIVE source_priority_root from priority_id when source exists but root not provided
    IF p_thread ? 'source_priority_root' AND (p_thread ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_thread ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL
            AND v_priority_id IS NOT NULL THEN
            SELECT
                subpath (p.path, 0, 1) INTO v_source_priority_root
            FROM
                priority p
            WHERE
                p.id = v_priority_id;
    END IF;
    -- Resolve id from source if not provided (for twist-created threads)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            a.id INTO v_id
        FROM
            thread a
        WHERE
            a.source = v_source
            AND a.source_priority_root = v_source_priority_root;
    END IF;
    -- Generate id if still not resolved
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_thread.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- DERIVE created_by_twist_id from created_by (priority_twist_id)
    IF p_thread ? 'created_by_twist_id' AND (p_thread ->> 'created_by_twist_id') IS NOT NULL THEN
        v_created_by_twist_id := (p_thread ->> 'created_by_twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_created_by_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;
    -- DERIVE default assignee for actions when assignee_id key is absent from both p_thread and p_defaults
    -- If key exists in p_thread (even with null value), use that value
    -- If key exists in p_defaults (even with null value), use that value
    -- If key is absent from both AND type is action, derive from priority_twist owner
    IF p_thread ? 'assignee_id' THEN
        v_assignee_id := (p_thread ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSIF v_type = 'action'
            AND v_created_by IS NOT NULL THEN
            v_assignee_id := get_priority_twist_owner_contact (v_created_by);
    ELSE
        v_assignee_id := NULL;
    END IF;
    -- Check if existing thread is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (thread.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = thread.priority_id
                    AND upe.user_id = upsert_thread.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        thread
    WHERE
        id = v_id;
    -- If no existing thread, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_thread
    INSERT INTO thread (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, done_at, meta, actions, source, updated_by, sync_depth, embedding, pick_priority, private, draft, "order")
        VALUES (v_id, v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_thread ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_thread -> 'meta', p_defaults -> 'meta'), COALESCE(p_thread -> 'actions', p_defaults -> 'actions'), v_source, COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_thread ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_thread -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE((p_thread ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first()))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            done_at = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz, thread.done_at)
            ELSE
                CASE WHEN p_thread ? 'done_at' THEN
                    (p_thread ->> 'done_at')::timestamptz
                ELSE
                    thread.done_at
                END
            END,
            meta = CASE WHEN v_is_archived THEN
                COALESCE(p_thread -> 'meta', p_defaults -> 'meta', thread.meta)
            ELSE
                CASE WHEN p_thread ? 'meta' THEN
                    p_thread -> 'meta'
                ELSE
                    thread.meta
                END
            END,
            actions = CASE WHEN v_is_archived THEN
                COALESCE(p_thread -> 'actions', p_defaults -> 'actions', thread.actions)
            ELSE
                CASE WHEN p_thread ? 'actions' THEN
                    p_thread -> 'actions'
                ELSE
                    thread.actions
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            type = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'type')::thread_type, (p_defaults ->> 'type')::thread_type, thread.type)
            ELSE
                CASE WHEN p_thread ? 'type' THEN
                    (p_thread ->> 'type')::thread_type
                ELSE
                    thread.type
                END
            END,
            assignee_id = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_assignee_id, thread.assignee_id)
            ELSE
                CASE WHEN p_thread ? 'assignee_id' THEN
                    (p_thread ->> 'assignee_id')::uuid
                ELSE
                    COALESCE(v_assignee_id, thread.assignee_id)
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, thread.private)
            ELSE
                CASE WHEN p_thread ? 'private' THEN
                    (p_thread ->> 'private')::boolean
                ELSE
                    thread.private
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            source = COALESCE(v_source, thread.source),
            source_priority_root = COALESCE(v_source_priority_root, thread.source_priority_root),
            created_by = v_created_by,
            created_by_twist_id = v_created_by_twist_id,
            "order" = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, thread."order")
            ELSE
                CASE WHEN p_thread ? 'order' THEN
                    (p_thread ->> 'order')::double precision
                ELSE
                    thread."order"
                END
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Create "priority_twist_thread_update" view
CREATE VIEW "public"."priority_twist_thread_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "done_at",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.done_at,
    a.source,
    a.meta,
    public.get_thread_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id = a.created_by AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Create "schedule" view
CREATE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
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
  "priority_path",
  "range_at",
  "range_on"
) AS SELECT upe.user_id,
    s.id,
    s.created_at,
    s.updated_at,
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
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on
   FROM public.schedule s
     JOIN public.thread a ON a.id = s.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE s.user_id IS NULL OR s.user_id = upe.user_id;
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "done_at",
  "meta",
  "actions",
  "source",
  "created_by_twist_id",
  "embedding",
  "pick_priority",
  "last_note_created_at",
  "last_note_source_created_at",
  "source_priority_root",
  "priority_path",
  "mentions"
) AS SELECT a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.done_at,
    a.meta,
    a.actions,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    public.get_thread_mentions(a.id) AS mentions
   FROM public.thread a
     JOIN public.priority p ON p.id = a.priority_id;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "assignee_id",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "done_at",
  "meta",
  "actions",
  "source",
  "created_by_twist_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "unread"
) AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.done_at,
    a.meta,
    a.actions,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END
            ELSE false
        END, false) AS unread
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.done_at,
    NULL::jsonb AS meta,
    NULL::jsonb AS actions,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    false AS unread
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR (ua.user_id = ANY (n.mentions)));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    at.tags
   FROM public.thread_tags at
     JOIN "user".thread ua ON ua.id = at.thread_id;
-- Create "priority_twist_thread_create" view
CREATE VIEW "public"."priority_twist_thread_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "done_at",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT pt.id AS priority_twist_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.done_at,
    a.source,
    a.meta,
    public.get_thread_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id <> a.created_by AND a.archived_at IS NULL AND pt.archived_at IS NULL AND a.created_at > pt.created_at
  ORDER BY a.created_at;
-- Drop "delete_thread_user_state" function
DROP FUNCTION "user"."delete_thread_user_state";
-- Drop "upsert_thread_exception" function
DROP FUNCTION "user"."upsert_thread_exception";
-- Drop "thread_exception" table
DROP TABLE "public"."thread_exception";
-- Drop "upsert_thread_user_state" function
DROP FUNCTION "user"."upsert_thread_user_state";
-- Drop "thread_user_state" table
DROP TABLE "public"."thread_user_state";
-- Drop "set_thread_order_on_start" function
DROP FUNCTION "public"."set_thread_order_on_start";
-- Drop "sync_user_for_thread_user_state" function
DROP FUNCTION "public"."sync_user_for_thread_user_state";
