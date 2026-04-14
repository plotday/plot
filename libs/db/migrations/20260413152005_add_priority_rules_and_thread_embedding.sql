-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "embedding" public.halfvec(384) NULL;
-- Create index "idx_thread_embedding" to table: "thread"
CREATE INDEX "idx_thread_embedding" ON "public"."thread" USING HNSW ("embedding" public.halfvec_cosine_ops);
-- Set comment to column: "embedding" on table: "thread"
COMMENT ON COLUMN "public"."thread"."embedding" IS 'Content embedding (384-dim halfvec) generated at creation from title + initial notes. Used by classify_thread_for_user for content-based priority rule matching.';
-- Create "priority_rule" table
CREATE TABLE "public"."priority_rule" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "channel_id" bigint NULL,
  "type" text NOT NULL,
  "embedding" public.halfvec(384) NULL,
  "criteria" jsonb NULL,
  "label" text NULL,
  "anchor_thread_id" uuid NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "priority_rule_anchor_thread_id_fkey" FOREIGN KEY ("anchor_thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE SET NULL,
  CONSTRAINT "priority_rule_channel_id_fkey" FOREIGN KEY ("channel_id") REFERENCES "public"."channel" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_rule_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_rule_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_rule_type_check" CHECK (type = ANY (ARRAY['content'::text, 'contact_topics'::text, 'channel'::text]))
);
-- Create index "idx_priority_rule_embedding" to table: "priority_rule"
CREATE INDEX "idx_priority_rule_embedding" ON "public"."priority_rule" USING HNSW ("embedding" public.halfvec_cosine_ops);
-- Create index "idx_priority_rule_priority" to table: "priority_rule"
CREATE INDEX "idx_priority_rule_priority" ON "public"."priority_rule" ("priority_id");
-- Create index "idx_priority_rule_updated_at" to table: "priority_rule"
CREATE INDEX "idx_priority_rule_updated_at" ON "public"."priority_rule" ("updated_at");
-- Create index "idx_priority_rule_user_channel" to table: "priority_rule"
CREATE INDEX "idx_priority_rule_user_channel" ON "public"."priority_rule" ("user_id", "channel_id");
-- Set comment to table: "priority_rule"
COMMENT ON TABLE "public"."priority_rule" IS 'User-defined rules for automatically filing threads into priorities. Rules are channel-scoped and evaluated in precedence order: content > contact_topics > channel.';
-- Set comment to column: "channel_id" on table: "priority_rule"
COMMENT ON COLUMN "public"."priority_rule"."channel_id" IS 'FK to channel.id (bigint). NULL means this rule applies to user-created threads (no connector). Non-null scopes to threads arriving from that specific channel.';
-- Set comment to column: "embedding" on table: "priority_rule"
COMMENT ON COLUMN "public"."priority_rule"."embedding" IS 'Frozen embedding snapshot for content rules. Compared against thread.embedding using cosine similarity with a 0.7 threshold.';
-- Set comment to column: "criteria" on table: "priority_rule"
COMMENT ON COLUMN "public"."priority_rule"."criteria" IS 'Match criteria for contact_topics rules. JSON object with optional "topics" (uuid[]) and "contacts" (uuid[]) arrays. Thread matches if it shares any listed topic or contact.';
-- Create "classify_thread_for_user" function
CREATE FUNCTION "public"."classify_thread_for_user" ("p_user_id" uuid, "p_thread_id" uuid DEFAULT NULL::uuid, "p_embedding" public.halfvec DEFAULT NULL::public.halfvec, "p_topics" uuid[] DEFAULT NULL::uuid[], "p_contacts" uuid[] DEFAULT NULL::uuid[], "p_channel_id" bigint DEFAULT NULL::bigint) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_embedding halfvec;
    v_topics uuid[];
    v_contacts uuid[];
    v_channel_id bigint;
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    -- 1. Load thread data from DB when thread exists, then apply overrides.
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topics, t.contacts
        INTO v_embedding, v_topics, v_contacts
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topics    := COALESCE(p_topics, v_topics, ARRAY[]::uuid[]);
    v_contacts  := COALESCE(p_contacts, v_contacts, ARRAY[]::uuid[]);

    -- 2. Resolve channel.
    --    Explicit override wins; otherwise derive from the thread's links.
    IF p_channel_id IS NOT NULL THEN
        v_channel_id := p_channel_id;
    ELSIF p_thread_id IS NOT NULL THEN
        SELECT c.id INTO v_channel_id
        FROM public.link l
        JOIN public.channel c
            ON c.twist_instance_id = l.created_by
           AND c.channel_id = l.channel_id
        WHERE l.thread_id = p_thread_id
          AND l.channel_id IS NOT NULL
        ORDER BY l.created_at DESC
        LIMIT 1;
    END IF;

    -- 3a. Content rules (highest precedence).
    IF v_embedding IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'content'
          AND pr.channel_id IS NOT DISTINCT FROM v_channel_id
          AND pr.embedding IS NOT NULL
          AND (1 - (pr.embedding <=> v_embedding)) >= 0.7
        ORDER BY (1 - (pr.embedding <=> v_embedding)) DESC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 3b. Contact / topic rules.
    IF cardinality(v_topics) > 0 OR cardinality(v_contacts) > 0 THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'contact_topics'
          AND pr.channel_id IS NOT DISTINCT FROM v_channel_id
          AND (
              (pr.criteria ? 'topics'
                  AND v_topics && ARRAY(
                      SELECT jsonb_array_elements_text(pr.criteria -> 'topics')
                  )::uuid[])
              OR
              (pr.criteria ? 'contacts'
                  AND v_contacts && ARRAY(
                      SELECT jsonb_array_elements_text(pr.criteria -> 'contacts')
                  )::uuid[])
          )
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 3c. Channel rule (lowest precedence, catch-all for a channel).
    IF v_channel_id IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'channel'
          AND pr.channel_id = v_channel_id
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    -- 4. Fall back to the user's root priority.
    SELECT p.id INTO v_root_priority_id
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$$;
-- Set comment to function: "classify_thread_for_user"
COMMENT ON FUNCTION "public"."classify_thread_for_user" IS 'Classify a thread into a priority for a user by evaluating their priority_rules in precedence order: content > contact_topics > channel > root fallback. Accepts either a thread_id or raw parameters for pre-insert classification.';
-- Modify "match_priority_for_user" function
CREATE OR REPLACE FUNCTION "public"."match_priority_for_user" ("p_user_id" uuid, "query_embedding" text DEFAULT NULL::text, "p_thread_data" jsonb DEFAULT '{}', "p_required_filters" jsonb DEFAULT '{}', "p_scored_fields" jsonb DEFAULT '{}', "p_similarity_threshold" double precision DEFAULT 0.7) RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
    -- Legacy parameters are ignored; classification is now rule-based.
    RETURN public.classify_thread_for_user(p_user_id);
END;
$$;
-- Create trigger "set_priority_rule_created_at"
CREATE TRIGGER "set_priority_rule_created_at" BEFORE INSERT ON "public"."priority_rule" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_priority_rule_updated_at"
CREATE TRIGGER "set_priority_rule_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_rule" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "file_thread_priority_for_topic_members" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_for_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.topics IS NULL OR cardinality(NEW.topics) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.topics) AS arr(topic_id)
        JOIN public.topic_member tm ON tm.topic_id = arr.topic_id
        JOIN public.user_contact uc
          ON uc.contact_id = tm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Modify "file_thread_priority_on_topic_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_topic_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
    v_peer_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            v_peer_priority_id := public.classify_thread_for_user(v_peer_user_id, r_thread.thread_id);
            IF v_peer_priority_id IS NULL THEN
                CONTINUE;
            END IF;

            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN OLD;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.topic_id = ANY(t.topics)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.topics) AS tid
                        JOIN topic_member tm2 ON tm2.topic_id = tid
                        JOIN user_contact uc2 ON uc2.contact_id = tm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND tm2.topic_id != OLD.topic_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id
                  AND matched = TRUE;

                DELETE FROM thread_unread
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Compute old contacts for delta (empty on INSERT)
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Exclude the author (user_id or twist_instance owner) from peer filing
    -- so we don't double-insert against the author trigger.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING)
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads
    -- appear as unread for peers. Uses ON CONFLICT DO NOTHING to avoid
    -- overwriting existing read state.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Create "apply_priority_rule" function
CREATE FUNCTION "public"."apply_priority_rule" ("p_rule_id" uuid, "p_max_moves" integer DEFAULT 100) RETURNS TABLE ("thread_id" uuid, "old_priority_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_rule RECORD;
BEGIN
    -- Load the rule.
    SELECT * INTO v_rule
    FROM public.priority_rule
    WHERE id = p_rule_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS (
        -- Threads for this user in a different priority, matching channel scope.
        SELECT tp.thread_id, tp.priority_id AS current_priority_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        LEFT JOIN LATERAL (
            SELECT c.id AS resolved_channel_id
            FROM public.link l
            JOIN public.channel c
                ON c.twist_instance_id = l.created_by
               AND c.channel_id = l.channel_id
            WHERE l.thread_id = tp.thread_id
              AND l.channel_id IS NOT NULL
            ORDER BY l.created_at DESC
            LIMIT 1
        ) ch ON TRUE
        WHERE tp.user_id = v_rule.user_id
          AND tp.priority_id IS DISTINCT FROM v_rule.priority_id
          AND t.archived_at IS NULL
          AND t.draft = FALSE
          AND ch.resolved_channel_id IS NOT DISTINCT FROM v_rule.channel_id
    ),
    matched AS (
        SELECT c.thread_id, c.current_priority_id
        FROM candidates c
        JOIN public.thread t ON t.id = c.thread_id
        WHERE
            CASE v_rule.type
                WHEN 'content' THEN
                    t.embedding IS NOT NULL
                    AND v_rule.embedding IS NOT NULL
                    AND (1 - (t.embedding <=> v_rule.embedding)) >= 0.7
                WHEN 'contact_topics' THEN
                    (v_rule.criteria ? 'topics'
                        AND t.topics && ARRAY(
                            SELECT jsonb_array_elements_text(v_rule.criteria -> 'topics')
                        )::uuid[])
                    OR
                    (v_rule.criteria ? 'contacts'
                        AND t.contacts && ARRAY(
                            SELECT jsonb_array_elements_text(v_rule.criteria -> 'contacts')
                        )::uuid[])
                WHEN 'channel' THEN
                    TRUE  -- All threads in this channel match.
            END
        LIMIT p_max_moves
    ),
    -- Only move if no higher-precedence rule already classifies this thread
    -- into a different priority.
    filtered AS (
        SELECT m.thread_id, m.current_priority_id
        FROM matched m
        WHERE public.classify_thread_for_user(
            v_rule.user_id,
            m.thread_id
        ) IS NOT DISTINCT FROM v_rule.priority_id
    ),
    moved AS (
        UPDATE public.thread_priority tp
        SET priority_id = v_rule.priority_id
        FROM filtered f
        WHERE tp.thread_id = f.thread_id
          AND tp.user_id = v_rule.user_id
        RETURNING tp.thread_id, f.current_priority_id AS old_priority_id
    )
    SELECT moved.thread_id, moved.old_priority_id FROM moved;
END;
$$;
-- Set comment to function: "apply_priority_rule"
COMMENT ON FUNCTION "public"."apply_priority_rule" IS 'Retroactively apply a priority_rule to existing threads. Only moves threads where the rule is the highest-precedence match, capped at p_max_moves.';
-- Modify "thread_x" view
CREATE OR REPLACE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "topics",
  "embedding"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    topics,
    embedding
   FROM public.thread a;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "topics",
  "title",
  "preview",
  "icon",
  "has_embedding",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "urgency",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.topics,
    a.title,
    a.preview,
    a.icon,
    a.embedding IS NOT NULL AS has_embedding,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance
            ELSE NULL::smallint
        END, 0::smallint) AS importance,
    COALESCE(
        CASE
            WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency
            ELSE NULL::text
        END, NULL::text) AS urgency,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.topics && "user".user_topic_ids(tp.user_id));
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Drop "find_matching_threads_scored" function
DROP FUNCTION "public"."find_matching_threads_scored";
-- Data migration: backfill thread.embedding from link.embedding
-- Uses the newest link with an embedding for each thread.
UPDATE public.thread t
SET embedding = sub.embedding
FROM (
    SELECT DISTINCT ON (l.thread_id)
        l.thread_id,
        l.embedding
    FROM public.link l
    WHERE l.thread_id IS NOT NULL
      AND l.embedding IS NOT NULL
    ORDER BY l.thread_id, l.created_at DESC
) sub
WHERE t.id = sub.thread_id
  AND t.embedding IS NULL;
