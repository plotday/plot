-- Privileged removal of contacts from a thread, intended for platform use
-- only. Bypasses `share_thread`'s user access-control check because the
-- caller (workers/api/src/twist/tools/plot/link.ts:createLink) has
-- independently determined that the removal is correct based on the 50%
-- removal heuristic for message-mode threads.
--
-- This sibling to `share_thread`:
--   - Does NOT validate `p_user_id` (no such parameter — platform is the
--     trust principal).
--   - Removes IDs from `thread.contacts` and strips their `contact_meta`
--     entries.
--   - Does NOT touch `thread_priority` rows: the existing `user.thread`
--     visibility filter (`thread.contacts && user_contact_ids`)
--     automatically excludes the dropped user once their contact id is
--     no longer in the array. The stale `thread_priority` row remains
--     until the access-loss redaction pattern is wired here (see
--     libs/db/AGENTS.md "Handling Access Loss to Synced Entities") —
--     same gap that `share_thread`'s remove path has today.
--   - Fires the existing thread `seq` bump trigger so clients re-sync.
--
-- Connectors MUST NOT call this directly. The reconciliation decision
-- happens in `workers/api/src/twist/sharing.ts:reconcileAndComputeRemovals`
-- (which wraps the pure `reconcileThreadContacts` helper) inside platform
-- API code; connectors only supply the `saveLink` payload that the
-- heuristic compares against.
CREATE OR REPLACE FUNCTION public.prune_thread_contacts (
    p_thread_id uuid,
    p_remove_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_contacts uuid[];
    v_new_contacts uuid[];
    v_current_meta jsonb;
    v_new_meta jsonb;
    v_contact_id uuid;
BEGIN
    -- Early exit when nothing to remove.
    IF p_remove_contact_ids IS NULL OR cardinality(p_remove_contact_ids) = 0 THEN
        RETURN;
    END IF;

    -- Fetch current state.
    SELECT contacts, contact_meta
      INTO v_current_contacts, v_current_meta
    FROM thread
    WHERE id = p_thread_id;

    -- Thread doesn't exist or has no contacts — nothing to do.
    IF v_current_contacts IS NULL OR cardinality(v_current_contacts) = 0 THEN
        RETURN;
    END IF;
    IF v_current_meta IS NULL THEN
        v_current_meta := '{}'::jsonb;
    END IF;

    -- Compute new contacts: current minus the removal set, preserving order.
    SELECT COALESCE(array_agg(cid ORDER BY ord), ARRAY[]::uuid[])
      INTO v_new_contacts
    FROM unnest(v_current_contacts) WITH ORDINALITY AS arr(cid, ord)
    WHERE cid != ALL(p_remove_contact_ids);

    -- No-op if the removal set didn't actually overlap.
    IF cardinality(v_new_contacts) = cardinality(v_current_contacts) THEN
        RETURN;
    END IF;

    -- Strip removed contacts' meta entries.
    v_new_meta := v_current_meta;
    FOREACH v_contact_id IN ARRAY p_remove_contact_ids LOOP
        v_new_meta := v_new_meta - (v_contact_id::text);
    END LOOP;

    -- Update thread. Fires the existing seq/updated_at trigger; the
    -- file_thread_priority_peers trigger no-ops for removals (only inserts
    -- for added contacts). Visibility filter on user.thread handles the
    -- "dropped user can no longer see this thread" effect automatically.
    UPDATE thread
       SET contacts = v_new_contacts,
           contact_meta = v_new_meta
     WHERE id = p_thread_id;
END;
$function$;

COMMENT ON FUNCTION public.prune_thread_contacts (uuid, uuid[]) IS
    'Privileged removal of contacts from a thread, intended for platform '
    'use only (see workers/api/src/twist/tools/plot/link.ts). Bypasses '
    'share_thread''s user access-control check.';
