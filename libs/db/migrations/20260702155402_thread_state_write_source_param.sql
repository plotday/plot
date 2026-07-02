-- Drop "upsert_thread_state" function
DROP FUNCTION "user"."upsert_thread_state" (uuid, uuid, boolean, boolean, smallint, timestamptz, timestamptz, timestamptz, double precision, daterange, tstzrange, boolean, boolean, boolean, boolean, boolean, boolean, boolean);
-- Create "upsert_thread_state" function
CREATE FUNCTION "user"."upsert_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_active" boolean DEFAULT false, "p_urgent" boolean DEFAULT false, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_order" double precision DEFAULT NULL::double precision, "p_on" daterange DEFAULT NULL::daterange, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_set_active" boolean DEFAULT false, "p_set_urgent" boolean DEFAULT false, "p_set_importance" boolean DEFAULT false, "p_set_read_at" boolean DEFAULT false, "p_set_order" boolean DEFAULT false, "p_set_on" boolean DEFAULT false, "p_set_at" boolean DEFAULT false, "p_write_source" uuid DEFAULT NULL::uuid) RETURNS "public"."thread_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_revoked_at timestamptz;
    v_tp_found boolean;
    v_row thread_state;
BEGIN
    -- Provenance for connector write-back echo suppression: stamps the
    -- thread_state trigger via a txn-local GUC (single statement = own txn,
    -- so the trigger fired within the write sees it; '' clears it so it can't
    -- leak to a later RPC in the same withUserDb transaction).
    PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);

    SELECT
        tp.priority_id, tp.revoked_at, TRUE
        INTO v_priority_id, v_revoked_at, v_tp_found
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
-- Modify "apply_pending_thread_state" function
CREATE OR REPLACE FUNCTION "public"."apply_pending_thread_state" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_payload jsonb;
    v_priority_id uuid;
    v_revoked_at timestamptz;
BEGIN
    -- Cheap check first: skip without touching pending_thread_state if
    -- the filing isn't ready. Most INSERTs on thread_priority for peers
    -- start with priority_id NULL and would otherwise force a pointless
    -- pending lookup on every insert.
    SELECT tp.priority_id, tp.revoked_at
      INTO v_priority_id, v_revoked_at
      FROM public.thread_priority tp
     WHERE tp.thread_id = p_thread_id
       AND tp.user_id = p_user_id;
    IF v_priority_id IS NULL OR v_revoked_at IS NOT NULL THEN
        RETURN;
    END IF;

    SELECT payload INTO v_payload
      FROM public.pending_thread_state
     WHERE user_id = p_user_id
       AND thread_id = p_thread_id;
    IF v_payload IS NULL THEN
        RETURN;
    END IF;

    -- Delete BEFORE the recursive call so the apply path doesn't re-defer
    -- (the call into upsert_thread_state runs its own thread_priority
    -- check, which we know passes, but belt-and-braces: the pending row
    -- is gone before any new write can land).
    DELETE FROM public.pending_thread_state
     WHERE user_id = p_user_id
       AND thread_id = p_thread_id;

    -- Reconstruct the original call. NULLs in the payload deserialize
    -- back to NULL; the set_* booleans default to FALSE.
    PERFORM "user".upsert_thread_state(
        p_user_id,
        p_thread_id,
        COALESCE((v_payload ->> 'p_active')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_urgent')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_importance')::smallint, 50::smallint),
        (v_payload ->> 'p_read_at')::timestamptz,
        (v_payload ->> 'p_bumped_at')::timestamptz,
        (v_payload ->> 'p_note_created_at')::timestamptz,
        (v_payload ->> 'p_order')::double precision,
        (v_payload ->> 'p_on')::daterange,
        (v_payload ->> 'p_at')::tstzrange,
        COALESCE((v_payload ->> 'p_set_active')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_urgent')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_importance')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_read_at')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_order')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_on')::boolean, FALSE),
        COALESCE((v_payload ->> 'p_set_at')::boolean, FALSE),
        (v_payload ->> 'p_write_source')::uuid
    );
END;
$$;
-- Drop "clear_thread_state" function
DROP FUNCTION "user"."clear_thread_state" (uuid, uuid, timestamptz, timestamptz);
-- Create "clear_thread_state" function
CREATE FUNCTION "user"."clear_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz DEFAULT now(), "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_write_source" uuid DEFAULT NULL::uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_threshold timestamptz;
BEGIN
    PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = clear_thread_state.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Freshness threshold for the read guard: the newest content visible to this
    -- user that they did NOT author themselves. A note the user wrote is content
    -- they have obviously seen, so it must not block their own read marker.
    -- Otherwise "read on web, reply, open another device" leaves the thread
    -- unread everywhere: the read marker is captured at open time, the user's own
    -- reply then advances thread.last_note_source_created_at past it, and the
    -- deferred /sync/thread-state push of that now-stale marker gets silently
    -- rejected. We therefore recompute the unscoped component as MAX over notes
    -- the user did not author (mirroring the unscoped filter the
    -- update_thread_on_note_change trigger applies to thread.last_note_source_created_at:
    -- non-draft, non-archived, access_contacts/access_groups both NULL), and keep
    -- the per-user scoped component (thread_state.last_note_source_created_at) as
    -- is. Truncated to ms to match client (JS Date) precision (see PRECISION
    -- BOUNDARY comment above).
    SELECT date_trunc('milliseconds',
               COALESCE(
                   GREATEST(
                       (SELECT MAX(n.source_created_at)
                        FROM note n
                        WHERE n.thread_id = p_thread_id
                          AND n.draft = FALSE
                          AND n.archived_at IS NULL
                          AND n.access_contacts IS NULL
                          AND n.access_groups IS NULL
                          AND n.created_by <> clear_thread_state.user_id),
                       ts.last_note_source_created_at),
                   t.created_at))
        INTO v_threshold
    FROM thread t
    LEFT JOIN thread_state ts
        ON ts.thread_id = t.id AND ts.user_id = clear_thread_state.user_id
    WHERE t.id = p_thread_id;

    INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
        VALUES (clear_thread_state.user_id, p_thread_id, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = CASE
                WHEN thread_state.read_at IS NULL
                    AND p_read_at >= v_threshold
                THEN p_read_at
                ELSE thread_state.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_state.bumped_at END,
            updated_at = now()
        WHERE
            p_bumped_at IS NOT NULL
            OR (thread_state.read_at IS NULL
                AND p_read_at >= v_threshold);
END;
$$;
