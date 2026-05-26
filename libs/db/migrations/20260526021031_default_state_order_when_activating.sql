-- Modify "upsert_thread_state" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_active" boolean DEFAULT false, "p_task" boolean DEFAULT false, "p_to_read" boolean DEFAULT false, "p_urgent" boolean DEFAULT false, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_order" double precision DEFAULT NULL::double precision, "p_on" daterange DEFAULT NULL::daterange, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_set_active" boolean DEFAULT false, "p_set_task" boolean DEFAULT false, "p_set_to_read" boolean DEFAULT false, "p_set_urgent" boolean DEFAULT false, "p_set_importance" boolean DEFAULT false, "p_set_read_at" boolean DEFAULT false, "p_set_order" boolean DEFAULT false, "p_set_on" boolean DEFAULT false, "p_set_at" boolean DEFAULT false) RETURNS "public"."thread_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_state;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_state.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    INSERT INTO thread_state (user_id, thread_id, active, task, to_read, urgent, importance, read_at, bumped_at, "order", "on", "at")
        VALUES (
            upsert_thread_state.user_id,
            p_thread_id,
            COALESCE(p_active, FALSE),
            COALESCE(p_task, FALSE),
            COALESCE(p_to_read, FALSE),
            COALESCE(p_urgent, FALSE),
            COALESCE(p_importance, 50),
            -- If the caller didn't opt in to writing read_at, default to now()
            -- so a brand-new row doesn't accidentally signal "unread". Without
            -- this guard a payload like {active: true} on a thread with no
            -- prior thread_state row would insert read_at=NULL and the
            -- user.thread view would flip unread=true.
            CASE WHEN p_set_read_at THEN p_read_at ELSE now() END,
            p_bumped_at,
            -- Default state_order when a row is being created with active=true
            -- and the caller didn't pass an order. NULL state_order makes the
            -- Flutter Doing/Scheduled sort behave non-deterministically (see
            -- Thread.order's doc) and prevents users from drag-reordering
            -- above such rows. Format mirrors Flutter's Order.first():
            -- `-millisecondsSinceEpoch + random()` so new rows sort at the top
            -- of Doing in ascending order.
            COALESCE(
                p_order,
                CASE WHEN COALESCE(p_active, FALSE)
                    THEN (-EXTRACT(EPOCH FROM clock_timestamp()) * 1000) + random()
                END
            ),
            p_on,
            p_at
        )
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            active = CASE WHEN p_set_active THEN EXCLUDED.active ELSE thread_state.active END,
            task = CASE WHEN p_set_task THEN EXCLUDED.task ELSE thread_state.task END,
            to_read = CASE WHEN p_set_to_read THEN EXCLUDED.to_read ELSE thread_state.to_read END,
            urgent = CASE WHEN p_set_urgent THEN EXCLUDED.urgent ELSE thread_state.urgent END,
            importance = CASE WHEN p_set_importance THEN EXCLUDED.importance ELSE thread_state.importance END,
            -- See INSERT branch above for why we default order on activation.
            -- This UPDATE branch handles the case where an existing row is
            -- being flipped from active=false to active=true without an
            -- explicit order; if order is already set we keep it.
            "order" = CASE
                WHEN p_set_order THEN EXCLUDED."order"
                WHEN p_set_active AND COALESCE(p_active, FALSE)
                    AND thread_state."order" IS NULL
                    THEN (-EXTRACT(EPOCH FROM clock_timestamp()) * 1000) + random()
                ELSE thread_state."order"
            END,
            "on" = CASE WHEN p_set_on THEN EXCLUDED."on" ELSE thread_state."on" END,
            "at" = CASE WHEN p_set_at THEN EXCLUDED."at" ELSE thread_state."at" END,
            read_at = CASE
                -- Caller didn't opt in to writing read_at → preserve existing.
                WHEN NOT p_set_read_at THEN thread_state.read_at
                -- Race condition: user read after the note was created → preserve their read
                -- Truncate to ms precision (see PRECISION BOUNDARY comment above)
                WHEN p_note_created_at IS NOT NULL
                    AND thread_state.read_at IS NOT NULL
                    AND thread_state.read_at >= date_trunc('milliseconds', p_note_created_at)
                THEN thread_state.read_at
                -- Caller opted in: use their value (NULL = mark unread)
                ELSE EXCLUDED.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_state.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;

-- Backfill: existing thread_state rows with active = TRUE but no state_order
-- predate the fix above and break Doing-section drag reorders client-side
-- (see Flutter Thread.order). Assign each a fresh order in the same shape
-- the upsert function now generates so they slot in at the top of Doing
-- (ascending sort). Sort is by content_timestamp so older threads land
-- deeper than newer ones, matching the activity_at secondary sort in the
-- unified feed builder. Updated_at bumps so existing user_sync triggers
-- propagate the change to clients without a fresh login.
UPDATE thread_state
SET
    "order" = (-EXTRACT(EPOCH FROM clock_timestamp()) * 1000) + random(),
    updated_at = now()
WHERE active = TRUE AND "order" IS NULL;
