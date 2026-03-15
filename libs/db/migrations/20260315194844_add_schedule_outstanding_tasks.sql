-- Drop "schedule" view
DROP VIEW "user"."schedule";
-- Modify "schedule" table
ALTER TABLE "public"."schedule" ADD COLUMN "outstanding_tasks" boolean NOT NULL DEFAULT false;
-- Create "recompute_outstanding_tasks" function
CREATE FUNCTION "public"."recompute_outstanding_tasks" ("p_thread_id" uuid, "p_user_id" uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_has_outstanding boolean;
BEGIN
    -- Check 1: Notes with active todo tag for any of the user's contacts
    SELECT EXISTS(
        SELECT 1
        FROM note_tag nt
        JOIN note n ON n.id = nt.note_id
        JOIN contact c ON c.id = nt.actor_id
        WHERE n.thread_id = p_thread_id
          AND c.user_id = p_user_id
          AND nt.tag_id = 1  -- Tag.todo
          AND nt.archived_at IS NULL
          AND n.archived_at IS NULL
    ) INTO v_has_outstanding;

    -- Check 2: Links assigned to user (or unassigned) with non-done status
    IF NOT v_has_outstanding THEN
        SELECT EXISTS(
            SELECT 1
            FROM link l
            JOIN contact c ON c.user_id = p_user_id
            JOIN priority_twist pt ON pt.id = l.created_by
            JOIN twist tw ON tw.id = pt.twist_id
            CROSS JOIN LATERAL jsonb_array_elements(tw.permissions -> '_providers') AS provider
            CROSS JOIN LATERAL jsonb_array_elements(provider -> 'linkTypes') AS lt
            CROSS JOIN LATERAL jsonb_array_elements(lt -> 'statuses') AS status_def
            WHERE l.thread_id = p_thread_id
              AND l.status IS NOT NULL
              AND (l.assignee_id IS NULL OR l.assignee_id = c.id)
              AND lt ->> 'type' = l.type
              AND status_def ->> 'status' = l.status
              AND COALESCE((status_def ->> 'done')::boolean, false) = false
        ) INTO v_has_outstanding;
    END IF;

    -- Update the per-user schedule
    UPDATE schedule
    SET outstanding_tasks = v_has_outstanding
    WHERE thread_id = p_thread_id
      AND user_id = p_user_id
      AND occurrence IS NULL;
END;
$$;
-- Modify "upsert_schedule" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule" ("user_id" uuid, "p_schedule" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."schedule" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_thread_id uuid;
    v_link_id uuid;
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
    v_link_id := COALESCE((p_schedule ->> 'link_id')::uuid, (p_defaults ->> 'link_id')::uuid);
    v_schedule_user_id := COALESCE((p_schedule ->> 'user_id')::uuid, (p_defaults ->> 'user_id')::uuid);

    -- Resolve thread_id/link_id from existing schedule if updating
    IF v_thread_id IS NULL AND v_link_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            s.thread_id, s.link_id INTO v_thread_id, v_link_id
        FROM
            schedule s
        WHERE
            s.id = v_id;
    END IF;

    -- Must have either thread_id or link_id
    IF v_thread_id IS NULL AND v_link_id IS NULL THEN
        RAISE EXCEPTION 'thread_id or link_id must be provided';
    END IF;

    -- Look up priority for access check
    IF v_thread_id IS NOT NULL THEN
        SELECT
            a.priority_id INTO v_priority_id
        FROM
            thread a
        WHERE
            a.id = v_thread_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
    ELSIF v_link_id IS NOT NULL THEN
        SELECT
            t.priority_id INTO v_priority_id
        FROM
            link l
            JOIN thread t ON t.id = l.thread_id
        WHERE
            l.id = v_link_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Link not found';
        END IF;
    END IF;

    PERFORM "user".assert_priority_access(upsert_schedule.user_id, v_priority_id);
    -- Enforce viewer restriction: viewers cannot create or modify schedules
    IF "user".get_effective_role(upsert_schedule.user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot create or modify schedules';
    END IF;

    -- Per-user schedules can only be created/modified by the owning user
    IF v_schedule_user_id IS NOT NULL AND v_schedule_user_id != upsert_schedule.user_id THEN
        RAISE EXCEPTION 'Cannot create/modify per-user schedule for another user';
    END IF;

    -- Resolve to existing schedule ID based on unique constraints.
    -- This prevents unique constraint violations when client and server
    -- have different UUIDs for the same logical schedule.
    DECLARE
        v_occurrence text;
        v_existing_id uuid;
    BEGIN
        v_occurrence := COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence');

        IF v_occurrence IS NOT NULL THEN
            -- Occurrence override: resolve by (link_id/thread_id, occurrence)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.occurrence = v_occurrence;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.occurrence = v_occurrence;
            END IF;
        ELSIF v_schedule_user_id IS NOT NULL THEN
            -- Per-user base schedule: resolve by (link_id/thread_id, user_id)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            END IF;
        ELSE
            -- Shared base schedule: resolve by (link_id/thread_id, user_id IS NULL)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            END IF;
        END IF;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END;

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
    INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, reason, archived_at, outstanding_tasks)
        VALUES (
            v_id,
            v_thread_id,
            v_link_id,
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
            COALESCE(p_schedule ->> 'reason', p_defaults ->> 'reason'),
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz),
            COALESCE((p_schedule ->> 'outstanding_tasks')::boolean, (p_defaults ->> 'outstanding_tasks')::boolean, FALSE)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            at = CASE WHEN p_schedule ? 'at' THEN
                (p_schedule ->> 'at')::tstzrange
            WHEN p_schedule ? 'on' THEN
                NULL -- Clear at when on is being set (XOR constraint)
            ELSE
                schedule.at
            END,
            "on" = CASE WHEN p_schedule ? 'on' THEN
                (p_schedule ->> 'on')::daterange
            WHEN p_schedule ? 'at' THEN
                NULL -- Clear on when at is being set (XOR constraint)
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
            "order" = CASE
                WHEN schedule.user_id IS NULL THEN NULL
                WHEN p_schedule ? 'order' THEN COALESCE((p_schedule ->> 'order')::double precision, schedule."order", public.order_first())
                ELSE COALESCE(schedule."order", public.order_first())
            END,
            reason = CASE WHEN p_schedule ? 'reason' THEN
                CASE
                    WHEN schedule.reason IS NULL THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'unread' AND (p_schedule ->> 'reason') IN ('task', 'add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'task' AND (p_schedule ->> 'reason') IN ('add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'add' AND (p_schedule ->> 'reason') = 'schedule' THEN 'schedule'
                    ELSE schedule.reason
                END
            ELSE schedule.reason
            END,
            archived_at = CASE WHEN p_schedule ? 'archived_at' THEN
                (p_schedule ->> 'archived_at')::timestamptz
            ELSE
                schedule.archived_at
            END,
            outstanding_tasks = CASE WHEN p_schedule ? 'outstanding_tasks' THEN
                (p_schedule ->> 'outstanding_tasks')::boolean
            ELSE
                schedule.outstanding_tasks
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
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
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
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
     LEFT JOIN public.thread t_thread ON t_thread.id = s.thread_id
     LEFT JOIN public.link l ON l.id = s.link_id
     LEFT JOIN public.thread t_link ON t_link.id = l.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = COALESCE(t_thread.priority_id, t_link.priority_id)
  WHERE s.user_id IS NULL OR s.user_id = upe.user_id;
-- Backfill outstanding_tasks for all existing per-user thread schedules
-- Note: only checks notes with todo tags. Link status checks are deferred
-- to runtime via recompute_outstanding_tasks() since the JSONB structure
-- in twist.permissions varies and CROSS JOIN LATERAL produces no rows
-- for twists without the expected structure.
UPDATE schedule s
SET outstanding_tasks = EXISTS(
    SELECT 1
    FROM note_tag nt
    JOIN note n ON n.id = nt.note_id
    JOIN contact c ON c.id = nt.actor_id
    WHERE n.thread_id = s.thread_id
      AND c.user_id = s.user_id
      AND nt.tag_id = 1
      AND nt.archived_at IS NULL
      AND n.archived_at IS NULL
)
WHERE s.user_id IS NOT NULL
  AND s.thread_id IS NOT NULL
  AND s.occurrence IS NULL;
