-- Flush pending_thread_state when a usable thread_priority row appears.
--
-- The Flutter client fires /sync/threads + /sync/notes + /sync/thread-state
-- as independent Worker invocations and they can land out of order. When
-- thread-state arrives before the thread_priority row exists (or while
-- it's still pending classification, or while it's revoked),
-- "user".upsert_thread_state stashes the payload in pending_thread_state
-- instead of raising. This trigger applies the stash as soon as the user
-- gains a settled, unrevoked filing.
--
-- Fired on:
--   * AFTER INSERT — covers the common race (author thread_priority row
--     inserted by upsert_thread, peers settled by file_thread_priority_peers
--     + workers/classify).
--   * AFTER UPDATE OF priority_id — covers the peer case where the row
--     starts pending (priority_id NULL) and the classifier sets it later.
--   * AFTER UPDATE OF revoked_at — covers the re-grant case (a user lost
--     access mid-race and is later re-added).
--
-- The function rechecks state before applying, so harmless extra fires
-- (e.g. UPDATE OF priority_id where revoked_at is still set) are no-ops.

CREATE OR REPLACE FUNCTION public.apply_pending_thread_state (
    p_user_id uuid,
    p_thread_id uuid
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.apply_pending_thread_state_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    PERFORM public.apply_pending_thread_state(NEW.user_id, NEW.thread_id);
    RETURN NULL;
END;
$function$;

CREATE TRIGGER apply_pending_thread_state_on_insert
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.apply_pending_thread_state_trigger ();

-- Cover the priority_id transition (peer rows settle from NULL → uuid via
-- workers/classify) and the revoked_at transition (re-grant after access
-- loss). Either of these unblocks a deferred payload.
CREATE TRIGGER apply_pending_thread_state_on_priority_or_revoke
    AFTER UPDATE OF priority_id, revoked_at ON public.thread_priority
    FOR EACH ROW
    WHEN (NEW.priority_id IS NOT NULL AND NEW.revoked_at IS NULL
          AND (OLD.priority_id IS DISTINCT FROM NEW.priority_id
               OR OLD.revoked_at IS DISTINCT FROM NEW.revoked_at))
    EXECUTE FUNCTION public.apply_pending_thread_state_trigger ();
