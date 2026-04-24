-- Compute thread_priority.applied_default_channel_id for a proposed
-- placement. Returns the channel pk when the thread's topic encodes a
-- channel, that channel belongs to p_user_id, and its default_priority_id
-- equals p_priority_id. Otherwise returns NULL.
--
-- Used by every path that writes thread_priority to keep the "this row was
-- placed by a channel default" marker consistent with whether the row
-- actually landed at the channel default.
CREATE OR REPLACE FUNCTION public.channel_default_marker (
    p_user_id uuid,
    p_thread_id uuid,
    p_priority_id uuid
)
    RETURNS bigint
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    v_topic text;
    v_channel_pk bigint;
    v_default_id uuid;
BEGIN
    IF p_user_id IS NULL OR p_thread_id IS NULL OR p_priority_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT t.topic INTO v_topic
    FROM public.thread t
    WHERE t.id = p_thread_id;

    IF v_topic IS NULL OR v_topic NOT LIKE 'channel:%' THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_channel_pk := NULLIF(substring(v_topic FROM 9), '')::bigint;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN NULL;
    END;

    IF v_channel_pk IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT c.default_priority_id INTO v_default_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = v_channel_pk
      AND ti.owner_id = p_user_id;

    IF v_default_id IS NOT NULL AND v_default_id = p_priority_id THEN
        RETURN v_channel_pk;
    END IF;

    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.channel_default_marker IS 'Return the channel pk if proposing to place (p_thread_id, p_user_id) at p_priority_id would land at the channel''s default_priority_id for this user, else NULL. Used by every writer of thread_priority.applied_default_channel_id.';
