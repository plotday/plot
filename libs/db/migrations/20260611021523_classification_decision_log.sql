-- Create "classification_decision" table
CREATE TABLE "public"."classification_decision" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "thread_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "priority_id" uuid NULL,
  "stage" text NOT NULL,
  "scores" jsonb NOT NULL DEFAULT '{}',
  "classifier" text NOT NULL,
  "llm_calls" integer NOT NULL DEFAULT 0,
  "cache_hits" integer NOT NULL DEFAULT 0,
  "budget_exhausted" boolean NOT NULL DEFAULT false,
  "duration_ms" real NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id")
);
-- Grant role access (matches 80-grants.sql; explicit so it does not depend on
-- ALTER DEFAULT PRIVILEGES state). api: full data access; readonly: SELECT.
GRANT SELECT, INSERT, UPDATE, DELETE ON "public"."classification_decision" TO api;
GRANT USAGE ON SEQUENCE "public"."classification_decision_id_seq" TO api;
GRANT SELECT ON "public"."classification_decision" TO readonly;
-- Create index "classification_decision_user_thread_idx" to table: "classification_decision"
CREATE INDEX "classification_decision_user_thread_idx" ON "public"."classification_decision" ("user_id", "thread_id", "created_at");
-- Set comment to table: "classification_decision"
COMMENT ON TABLE "public"."classification_decision" IS 'Append-only log of applied classification decisions (classifier stages, sql:applied trigger paths) and explicit user moves (stage=user_move). No FKs by design; not synced.';
-- Modify "apply_channel_default" function
CREATE OR REPLACE FUNCTION "public"."apply_channel_default" ("p_channel_id" bigint) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
    v_updated int;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    -- AS MATERIALIZED on both CTEs is load-bearing: classify_thread_for_user
    -- is STABLE, so without the fence the planner inlines `reclass` and
    -- pushes the outer `r.new_priority_id IS NOT NULL` filter into
    -- `candidates`'s thread_priority bitmap scan. That broadens the inner
    -- scan to every (user_id, priority_id=root) row instead of only
    -- candidates whose thread.topic matches this channel, and classify
    -- ends up called on every root-filed thread (≫ candidates). With the
    -- fence, candidates is computed once and classify is called exactly
    -- once per row. Reproduced 30s timeout vs. 47ms with materialization.
    WITH candidates AS MATERIALIZED (
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE

        UNION

        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    ),
    reclass AS MATERIALIZED (
        SELECT c.thread_id,
               c.user_id,
               public.classify_thread_for_user(c.user_id, c.thread_id) AS new_priority_id
        FROM candidates c
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                r.user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = r.user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND (
              r.new_priority_id IS DISTINCT FROM tp.priority_id
              OR public.channel_default_marker (
                     r.user_id, r.thread_id, r.new_priority_id
                 ) IS DISTINCT FROM tp.applied_default_channel_id
          )
        RETURNING tp.thread_id, tp.user_id, tp.priority_id
    ),
    logged AS (
        INSERT INTO public.classification_decision (thread_id, user_id, priority_id, stage, classifier)
        SELECT u.thread_id, u.user_id, u.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
        FROM updated u
    )
    SELECT COUNT(*) INTO v_updated FROM updated;

    RETURN v_updated;
END;
$$;
-- Modify "file_thread_priority_on_group_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_group_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN NEW; END IF;

        WITH affected AS (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ),
        candidates AS (
            SELECT a.thread_id, public.classify_thread_for_user(v_peer_user_id, a.thread_id) AS pid
            FROM affected a
        ),
        filed AS (
            INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
            SELECT c.thread_id, v_peer_user_id, c.pid,
                   CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
            FROM candidates c
            -- Re-join case: if a row already exists with revoked_at set
            -- (the user previously lost access), un-revoke it. Prior priority
            -- filing is preserved — we do not overwrite priority_id /
            -- classify_at. Rows without revoked_at are left alone (the user
            -- already had active access via another path).
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
            SET revoked_at = NULL
            WHERE thread_priority.revoked_at IS NOT NULL
            RETURNING thread_priority.thread_id, thread_priority.priority_id,
                      (xmax = 0) AS inserted
        )
        -- Decision log: only freshly-inserted, resolved filings are applied
        -- decisions. Un-revokes preserve the prior filing; pending rows
        -- (pid NULL) are decided later by the classify worker, which logs.
        INSERT INTO classification_decision (thread_id, user_id, priority_id, stage, classifier)
        SELECT f.thread_id, v_peer_user_id, f.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
        FROM filed f
        WHERE f.inserted AND f.priority_id IS NOT NULL;

        INSERT INTO thread_state (user_id, thread_id)
        SELECT v_peer_user_id, a.thread_id
        FROM (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ) a
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        RETURN NEW;

    -- DELETE: member removed from group. For every thread whose access
    -- came solely through this group (direct or via topic), mark the
    -- user's thread_priority row as revoked so "user".thread_redacted
    -- emits a cleanup stub (sensitive fields NULLed, archived_at =
    -- revoked_at, seq frozen) and the client hard-deletes its local copy.
    -- See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
    --
    -- Do NOT bare-DELETE thread_priority here — that would strand the
    -- client (no seq bump, no row in user.thread*, local row lives
    -- forever).
    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN OLD; END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = OLD.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
        LOOP
            IF NOT "user".user_has_thread_access(v_peer_user_id, r_thread.thread_id) THEN
                UPDATE thread_priority SET revoked_at = now()
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id AND revoked_at IS NULL;

                -- thread_state is consumed via "user".thread's LEFT JOIN;
                -- the redacted stub emits unread=false regardless, so the
                -- row is now meaningless. Bare DELETE is safe because the
                -- table is not directly synced — it feeds computed columns
                -- on user.thread, which is now serving the redacted stub.
                DELETE FROM thread_state
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
-- Modify "grant_topic_threads_to_user" function
CREATE OR REPLACE FUNCTION "public"."grant_topic_threads_to_user" ("p_topic_id" uuid, "p_user_id" uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Respect opt-out: a user who left does not get re-added by a membership change.
    IF EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = p_topic_id AND o.user_id = p_user_id) THEN
        RETURN;
    END IF;

    WITH candidates AS (
        SELECT t.id AS thread_id, public.classify_thread_for_user(p_user_id, t.id) AS pid
        FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ),
    filed AS (
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id, p_user_id, c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
        SET revoked_at = NULL
        WHERE thread_priority.revoked_at IS NOT NULL
        RETURNING thread_priority.thread_id, thread_priority.priority_id,
                  (xmax = 0) AS inserted
    )
    INSERT INTO classification_decision (thread_id, user_id, priority_id, stage, classifier)
    SELECT f.thread_id, p_user_id, f.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
    FROM filed f
    WHERE f.inserted AND f.priority_id IS NOT NULL;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT p_user_id, t.id
    FROM public.thread t
    WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ON CONFLICT (user_id, thread_id) DO NOTHING;
END;
$$;
