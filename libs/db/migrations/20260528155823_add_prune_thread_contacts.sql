-- Create "prune_thread_contacts" function
CREATE FUNCTION "public"."prune_thread_contacts" ("p_thread_id" uuid, "p_remove_contact_ids" uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
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
$$;
-- Set comment to function: "prune_thread_contacts"
COMMENT ON FUNCTION "public"."prune_thread_contacts" IS 'Privileged removal of contacts from a thread, intended for platform use only (see workers/api/src/twist/tools/plot/link.ts). Bypasses share_thread''s user access-control check.';
