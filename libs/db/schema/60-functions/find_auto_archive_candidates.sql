-- Find threads that match a seed thread's "Archive threads like this" rule.
--
-- The seed defines an auto-archive rule for a specific user. We surface every
-- other thread the user can see that is currently not archived and matches
-- the seed on:
--
--   1. Channel — at least one link.channel_id in common.
--   2. Author —
--        a. Same link.author_id on a link of the candidate (preferred,
--           covers email/Slack senders and calendar organizers).
--        b. If the seed has no link author (Plot-created thread), match on
--           thread.topic instead. Topic encodes the priority/group the
--           author filed the thread into and is the closest proxy.
--   3. Content —
--        a. normalize_title(candidate.title) = normalize_title(seed.title), or
--        b. cosine similarity of embeddings ≥ 0.85.
--
-- Returns nothing when the seed lacks enough signal (no channel, OR neither
-- author nor topic). The caller treats an empty set as "no fan-out" — the
-- seed still gets its own archive applied separately.
CREATE OR REPLACE FUNCTION "user".find_auto_archive_candidates (
    p_user_id uuid,
    p_seed_thread_id uuid
)
    RETURNS SETOF uuid
    LANGUAGE plpgsql
    STABLE
    AS $$
DECLARE
    v_seed_channels text[];
    v_seed_author uuid;
    v_seed_topic text;
    v_seed_title_norm text;
    v_seed_embedding public.halfvec;
    v_user_contacts uuid[];
    v_user_groups uuid[];
BEGIN
    -- Collect distinct channel ids across all links on the seed thread.
    SELECT array_agg(DISTINCT l.channel_id)
    INTO v_seed_channels
    FROM public.link l
    WHERE l.thread_id = p_seed_thread_id
      AND l.channel_id IS NOT NULL;

    -- Seed must have at least one channel signal — otherwise we can't
    -- bound the rule and a runaway match would surprise the user.
    IF v_seed_channels IS NULL OR cardinality(v_seed_channels) = 0 THEN
        RETURN;
    END IF;

    -- Pick the seed's link author (first non-null wins; usually only one).
    SELECT l.author_id
    INTO v_seed_author
    FROM public.link l
    WHERE l.thread_id = p_seed_thread_id
      AND l.author_id IS NOT NULL
    LIMIT 1;

    SELECT t.topic, t.embedding, public.normalize_title(t.title)
    INTO v_seed_topic, v_seed_embedding, v_seed_title_norm
    FROM public.thread t
    WHERE t.id = p_seed_thread_id;

    -- Need either author (from a link) or topic to identify the sender side.
    IF v_seed_author IS NULL AND v_seed_topic IS NULL THEN
        RETURN;
    END IF;

    v_user_contacts := "user".user_contact_ids(p_user_id);
    v_user_groups := "user".user_group_ids(p_user_id);

    RETURN QUERY
    SELECT t.id
    FROM public.thread t
    JOIN public.thread_priority tp
        ON tp.thread_id = t.id
       AND tp.user_id = p_user_id
       AND tp.archived_at IS NULL
    WHERE t.id <> p_seed_thread_id
      AND t.archived_at IS NULL
      AND (t.draft = FALSE OR t.created_by = p_user_id)
      AND (t.contacts && v_user_contacts OR t.groups && v_user_groups)
      -- Channel match (required).
      AND EXISTS (
          SELECT 1
          FROM public.link l
          WHERE l.thread_id = t.id
            AND l.channel_id = ANY (v_seed_channels)
      )
      -- Author OR topic match.
      AND (
          (v_seed_author IS NOT NULL AND EXISTS (
              SELECT 1
              FROM public.link l
              WHERE l.thread_id = t.id
                AND l.author_id = v_seed_author
          ))
          OR (v_seed_author IS NULL AND v_seed_topic IS NOT NULL AND t.topic = v_seed_topic)
      )
      -- Content match: normalized title OR embedding similarity.
      AND (
          (v_seed_title_norm IS NOT NULL
           AND public.normalize_title(t.title) = v_seed_title_norm)
          OR (v_seed_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (t.embedding <=> v_seed_embedding) <= 0.15)
      );
END;
$$;

COMMENT ON FUNCTION "user".find_auto_archive_candidates (uuid, uuid) IS
    'Returns thread ids the given user can see and that match the seed thread''s auto-archive rule (same channel + same link author (or topic when no link author) + similar title or embedding).';
