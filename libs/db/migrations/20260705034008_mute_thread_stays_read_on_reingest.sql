-- Modify "upsert_thread_state" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_active" boolean DEFAULT false, "p_urgent" boolean DEFAULT false, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_order" double precision DEFAULT NULL::double precision, "p_on" daterange DEFAULT NULL::daterange, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_set_active" boolean DEFAULT false, "p_set_urgent" boolean DEFAULT false, "p_set_importance" boolean DEFAULT false, "p_set_read_at" boolean DEFAULT false, "p_set_order" boolean DEFAULT false, "p_set_on" boolean DEFAULT false, "p_set_at" boolean DEFAULT false, "p_write_source" uuid DEFAULT NULL::uuid) RETURNS "public"."thread_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_revoked_at timestamptz;
    v_tp_found boolean;
    v_muted boolean;
    v_row thread_state;
BEGIN
    -- Provenance for connector write-back echo suppression: stamps the
    -- thread_state trigger via a txn-local GUC (single statement = own txn,
    -- so the trigger fired within the write sees it; '' clears it so it can't
    -- leak to a later RPC in the same withUserDb transaction).
    PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);

    SELECT
        tp.priority_id, tp.revoked_at, TRUE, tp.mute_by_thread_id IS NOT NULL
        INTO v_priority_id, v_revoked_at, v_tp_found, v_muted
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_state.user_id;

    -- Defer when the user has no usable filing yet (no row, pending
    -- classification, or revoked). The apply_pending_thread_state trigger
    -- on thread_priority will flush this row as soon as a settled,
    -- unrevoked filing lands. Note: an UPDATE EXCLUDED overwrite means a
    -- later push (e.g. the client retrying) wins over an earlier deferred
    -- one — which mirrors normal upsert_thread_state semantics on a
    -- successful write.
    IF NOT COALESCE(v_tp_found, FALSE) OR v_priority_id IS NULL OR v_revoked_at IS NOT NULL THEN
        INSERT INTO pending_thread_state (user_id, thread_id, payload)
        VALUES (
            upsert_thread_state.user_id,
            p_thread_id,
            jsonb_build_object(
                'p_active', p_active,
                'p_urgent', p_urgent,
                'p_importance', p_importance,
                'p_read_at', p_read_at,
                'p_bumped_at', p_bumped_at,
                'p_note_created_at', p_note_created_at,
                'p_order', p_order,
                'p_on', p_on,
                'p_at', p_at,
                'p_set_active', p_set_active,
                'p_set_urgent', p_set_urgent,
                'p_set_importance', p_set_importance,
                'p_set_read_at', p_set_read_at,
                'p_set_order', p_set_order,
                'p_set_on', p_set_on,
                'p_set_at', p_set_at,
                'p_write_source', p_write_source
            )
        )
        ON CONFLICT (user_id, thread_id) DO UPDATE SET
            payload = EXCLUDED.payload,
            created_at = now();
        RETURN NULL;
    END IF;

    INSERT INTO thread_state (user_id, thread_id, active, urgent, importance, read_at, bumped_at, "order", "on", "at")
        VALUES (
            upsert_thread_state.user_id,
            p_thread_id,
            COALESCE(p_active, FALSE),
            COALESCE(p_urgent, FALSE),
            COALESCE(p_importance, 50),
            -- If the caller didn't opt in to writing read_at, default to now()
            -- so a brand-new row doesn't accidentally signal "unread". Without
            -- this guard a payload like {active: true} on a thread with no
            -- prior thread_state row would insert read_at=NULL and the
            -- user.thread view would flip unread=true.
            --
            -- Muted-thread guard: a muted thread must never be resurfaced as
            -- unread by connector/queue note ingestion (the mute rule already
            -- marked it read + inactive). If the caller intends to mark unread
            -- (p_read_at NULL) but the thread is muted for this user, seed the
            -- row read (now()) instead. Normally a muted thread already has a
            -- thread_state row, so this INSERT branch is a defensive mirror of
            -- the UPDATE branch below.
            CASE
                WHEN p_set_read_at AND NOT (v_muted AND p_read_at IS NULL) THEN p_read_at
                ELSE now()
            END,
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
                -- Muted thread: the mute rule marked it read + inactive, and
                -- connector/queue note ingestion must not resurface it as
                -- unread. Preserve the existing read marker rather than nulling
                -- it. Gated on the caller's intent (p_read_at NULL = mark
                -- unread) rather than EXCLUDED.read_at, which the INSERT branch
                -- above may have rewritten to now() for a muted row. An explicit
                -- read (p_read_at NOT NULL) still writes through the ELSE below.
                -- Without this, an async unread writer (which passes its own
                -- ingest now() as p_note_created_at, newer than the mute's
                -- read_at) defeats the race guard below and clobbers read_at to
                -- NULL — the muted thread reappears unread in Active.
                WHEN v_muted AND p_read_at IS NULL THEN thread_state.read_at
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
