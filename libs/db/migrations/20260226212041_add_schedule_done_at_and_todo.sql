-- Create "propagate_note_tag_todo" function
CREATE FUNCTION "public"."propagate_note_tag_todo" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_thread_id uuid;
    v_user_id uuid;
BEGIN
    -- Only handle Tag.now (tag_id = 1) being added (not archived)
    IF NEW.tag_id != 1 OR NEW.archived_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- For UPDATE, only proceed if the tag was previously archived and is now unarchived
    IF TG_OP = 'UPDATE' AND OLD.archived_at IS NULL THEN
        RETURN NEW;
    END IF;

    -- Get thread_id from the note
    SELECT n.thread_id INTO v_thread_id
    FROM note n
    WHERE n.id = NEW.note_id;

    IF v_thread_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Get user_id from the actor's contact
    SELECT c.user_id INTO v_user_id
    FROM contact c
    WHERE c.id = NEW.actor_id;

    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Insert a per-user schedule (undated = current and ongoing todo)
    -- ON CONFLICT DO NOTHING: don't overwrite if one already exists
    INSERT INTO schedule (thread_id, user_id, "order")
        VALUES (v_thread_id, v_user_id, public.order_first())
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;
-- Create trigger "note_tag_todo_propagation"
CREATE TRIGGER "note_tag_todo_propagation" AFTER INSERT OR UPDATE ON "public"."note_tag" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_note_tag_todo"();
-- Drop "schedule" view
DROP VIEW "user"."schedule";
-- Modify "schedule" table
ALTER TABLE "public"."schedule" DROP CONSTRAINT "schedule_at_xor_on", ADD CONSTRAINT "schedule_at_xor_on" CHECK (((at IS NOT NULL) AND ("on" IS NULL)) OR ((at IS NULL) AND ("on" IS NOT NULL)) OR ((at IS NULL) AND ("on" IS NULL) AND (user_id IS NOT NULL))), ADD COLUMN "done_at" timestamptz NULL;
-- Create index "idx_schedule_done_at" to table: "schedule"
CREATE INDEX "idx_schedule_done_at" ON "public"."schedule" ("done_at") WHERE (done_at IS NOT NULL);
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
    INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, archived_at, done_at)
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
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz),
            COALESCE((p_schedule ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz)
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
            END,
            done_at = CASE WHEN p_schedule ? 'done_at' THEN
                (p_schedule ->> 'done_at')::timestamptz
            ELSE
                schedule.done_at
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
  "done_at",
  "thread_id",
  "link_id",
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
    s.done_at,
    s.thread_id,
    s.link_id,
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
