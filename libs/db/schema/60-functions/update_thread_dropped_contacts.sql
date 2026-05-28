-- Privileged management of the dropped_contacts set on a message-mode thread,
-- intended for platform use only. Bypasses `share_thread`'s user
-- access-control check because the caller
-- (workers/api/src/twist/tools/plot/link.ts:createLink) has independently
-- determined that the change is correct based on the 50% removal heuristic
-- for message-mode threads, or because the Flutter app is responding to a
-- user toggling a dropped contact in the sharing modal.
--
-- Design: "dropped" contacts remain in `thread.contacts` (so they retain
-- thread visibility via the `contacts && user_contact_ids` filter in
-- `user.thread`), but are recorded in `dropped_contacts` so clients exclude
-- them from outbound defaults, badge logic, and the active-participants list.
--
-- Invariant: every uuid in dropped_contacts MUST also appear in contacts.
-- This function maintains that invariant for the p_drop direction by only
-- appending IDs that are already present in contacts. p_undrop removes IDs
-- from dropped_contacts (restoring them to the active set).
--
-- Connectors MUST NOT call this directly. The reconciliation decision
-- happens in `workers/api/src/twist/sharing.ts` inside platform API code;
-- connectors only supply the `saveLink` payload that the heuristic compares
-- against.
CREATE OR REPLACE FUNCTION public.update_thread_dropped_contacts (
    p_thread_id uuid,
    p_drop uuid[] DEFAULT ARRAY[]::uuid[],
    p_undrop uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_contacts uuid[];
    v_current_dropped uuid[];
    v_new_dropped uuid[];
    v_current_meta jsonb;
    v_new_meta jsonb;
    v_contact_id uuid;
BEGIN
    -- Early exit when nothing to do.
    IF (p_drop IS NULL OR cardinality(p_drop) = 0)
        AND (p_undrop IS NULL OR cardinality(p_undrop) = 0) THEN
        RETURN;
    END IF;

    -- Fetch current state.
    SELECT contacts, dropped_contacts, contact_meta
      INTO v_current_contacts, v_current_dropped, v_current_meta
    FROM thread
    WHERE id = p_thread_id;

    -- Thread doesn't exist — nothing to do.
    IF v_current_contacts IS NULL THEN
        RETURN;
    END IF;
    IF v_current_dropped IS NULL THEN
        v_current_dropped := ARRAY[]::uuid[];
    END IF;
    IF v_current_meta IS NULL THEN
        v_current_meta := '{}'::jsonb;
    END IF;

    -- Compute new_dropped = (current_dropped ∪ p_drop) - p_undrop.
    -- Only include IDs in p_drop that are actually in contacts (invariant).
    SELECT COALESCE(array_agg(DISTINCT cid ORDER BY cid), ARRAY[]::uuid[])
      INTO v_new_dropped
    FROM (
        -- Existing dropped contacts not being undropped
        SELECT unnest AS cid
        FROM unnest(v_current_dropped)
        WHERE p_undrop IS NULL OR NOT (unnest = ANY(p_undrop))
        UNION
        -- New drops: only include IDs already in contacts
        SELECT unnest AS cid
        FROM unnest(p_drop)
        WHERE p_drop IS NOT NULL
          AND unnest = ANY(v_current_contacts)
          AND (p_undrop IS NULL OR NOT (unnest = ANY(p_undrop)))
    ) sub;

    -- Strip contact_meta entries for p_drop (they no longer have an active role).
    v_new_meta := v_current_meta;
    IF p_drop IS NOT NULL THEN
        FOREACH v_contact_id IN ARRAY p_drop LOOP
            v_new_meta := v_new_meta - (v_contact_id::text);
        END LOOP;
    END IF;

    -- No-op if nothing actually changed.
    IF v_new_dropped IS NOT DISTINCT FROM v_current_dropped
        AND v_new_meta IS NOT DISTINCT FROM v_current_meta THEN
        RETURN;
    END IF;

    -- Update thread. Fires the existing seq/updated_at trigger so clients
    -- re-sync and see the changed dropped_contacts array.
    -- Does NOT modify contacts — dropped contacts keep thread visibility.
    UPDATE thread
       SET dropped_contacts = v_new_dropped,
           contact_meta = v_new_meta
     WHERE id = p_thread_id;
END;
$function$;

COMMENT ON FUNCTION public.update_thread_dropped_contacts (uuid, uuid[], uuid[]) IS
    'Privileged management of the dropped_contacts set on a message-mode '
    'thread, intended for platform use only (see '
    'workers/api/src/twist/tools/plot/link.ts). Dropped contacts remain in '
    'thread.contacts (for visibility) but are excluded from the active '
    'recipient set. p_drop appends IDs (deduplicated, constrained to '
    'existing contacts); p_undrop removes IDs. Bypasses share_thread''s '
    'user access-control check.';
