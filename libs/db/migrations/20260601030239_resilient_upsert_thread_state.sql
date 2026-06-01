-- Create "pending_thread_state" table
CREATE TABLE "public"."pending_thread_state" (
  "user_id" uuid NOT NULL,
  "thread_id" uuid NOT NULL,
  "payload" jsonb NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("user_id", "thread_id")
);
-- Set comment to table: "pending_thread_state"
COMMENT ON TABLE "public"."pending_thread_state" IS 'Deferred upsert_thread_state payloads waiting for a usable thread_priority row to appear. Flushed by the apply_pending_thread_state trigger on thread_priority insert/update.';
-- Modify "upsert_thread_state" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_active" boolean DEFAULT false, "p_urgent" boolean DEFAULT false, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_order" double precision DEFAULT NULL::double precision, "p_on" daterange DEFAULT NULL::daterange, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_set_active" boolean DEFAULT false, "p_set_urgent" boolean DEFAULT false, "p_set_importance" boolean DEFAULT false, "p_set_read_at" boolean DEFAULT false, "p_set_order" boolean DEFAULT false, "p_set_on" boolean DEFAULT false, "p_set_at" boolean DEFAULT false) RETURNS "public"."thread_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_revoked_at timestamptz;
    v_tp_found boolean;
    v_row thread_state;
BEGIN
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
                'p_set_at', p_set_at
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
-- Create "apply_pending_thread_state" function
CREATE FUNCTION "public"."apply_pending_thread_state" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
        COALESCE((v_payload ->> 'p_set_at')::boolean, FALSE)
    );
END;
$$;
-- Create "apply_pending_thread_state_trigger" function
CREATE FUNCTION "public"."apply_pending_thread_state_trigger" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.apply_pending_thread_state(NEW.user_id, NEW.thread_id);
    RETURN NULL;
END;
$$;
-- Create trigger "apply_pending_thread_state_on_insert"
CREATE TRIGGER "apply_pending_thread_state_on_insert" AFTER INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."apply_pending_thread_state_trigger"();
-- Create trigger "apply_pending_thread_state_on_priority_or_revoke"
CREATE TRIGGER "apply_pending_thread_state_on_priority_or_revoke" AFTER UPDATE OF "priority_id", "revoked_at" ON "public"."thread_priority" FOR EACH ROW WHEN ((new.priority_id IS NOT NULL) AND (new.revoked_at IS NULL) AND ((old.priority_id IS DISTINCT FROM new.priority_id) OR (old.revoked_at IS DISTINCT FROM new.revoked_at))) EXECUTE FUNCTION "public"."apply_pending_thread_state_trigger"();
