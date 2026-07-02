-- Drop "note" view
DROP VIEW "user"."note";
-- Drop "note_redacted" view
DROP VIEW "user"."note_redacted";
-- Drop "note_reactions" view
DROP VIEW "user"."note_reactions";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "send_at" timestamptz NULL;
-- Create index "idx_note_send_at_pending" to table: "note"
CREATE INDEX "idx_note_send_at_pending" ON "public"."note" ("send_at") WHERE ((send_at IS NOT NULL) AND (draft = false) AND (archived_at IS NULL));
-- Modify "update_thread_last_note_created_at_on_status_change" trigger
CREATE OR REPLACE TRIGGER "update_thread_last_note_created_at_on_status_change" AFTER UPDATE OF "archived_at", "draft", "send_at", "source_created_at" ON "public"."note" FOR EACH ROW WHEN ((old.draft IS DISTINCT FROM new.draft) OR (old.archived_at IS DISTINCT FROM new.archived_at) OR (old.source_created_at IS DISTINCT FROM new.source_created_at) OR (old.send_at IS DISTINCT FROM new.send_at)) EXECUTE FUNCTION "public"."update_thread_on_note_change"();
-- Drop "thread_reactions" view
DROP VIEW "user"."thread_reactions";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Drop "thread_redacted" view
DROP VIEW "user"."thread_redacted";
-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "send_at" timestamptz NULL;
-- Modify "search_notes_and_links" function
CREATE OR REPLACE FUNCTION "public"."search_notes_and_links" ("query_embedding" text, "scope_priority_id" uuid, "requesting_user_id" uuid, "exclude_created_by" uuid DEFAULT NULL::uuid, "similarity_threshold" double precision DEFAULT 0.3, "match_limit" integer DEFAULT 20) RETURNS TABLE ("result_type" text, "result_id" uuid, "thread_id" uuid, "thread_title" text, "priority_id" uuid, "priority_title" text, "content" text, "title" text, "source_url" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM (
        -- Notes
        SELECT 'note'::text, n.id, n.thread_id, t.title, tp.priority_id,
               p.title, n.content, NULL::text, NULL::text,
               (1 - (n.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM note n
        JOIN thread t ON t.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id
                               AND tp.user_id = requesting_user_id
                               AND tp.priority_id = scope_priority_id
        JOIN priority p ON p.id = tp.priority_id
        WHERE n.embedding IS NOT NULL
          AND n.archived_at IS NULL AND n.draft = FALSE
          -- Scheduled-send hold: held notes are searchable only by their author
          AND (n.send_at IS NULL OR n.send_at <= now() OR n.created_by = requesting_user_id)
          AND t.archived_at IS NULL
          AND (t.send_at IS NULL OR t.send_at <= now() OR t.created_by = requesting_user_id)
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (
            n.created_by = requesting_user_id
            OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
            OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(requesting_user_id))
            OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(requesting_user_id))
          )
          AND (exclude_created_by IS NULL OR n.created_by != exclude_created_by)
          AND (1 - (n.embedding <=> query_embedding::halfvec)) >= similarity_threshold

        UNION ALL

        -- Threads (via thread.embedding)
        SELECT 'link'::text, l.id, l.thread_id, t.title, tp.priority_id,
               p.title, l.preview, l.title, l.source_url,
               (1 - (t.embedding <=> query_embedding::halfvec))::float AS similarity
        FROM link l
        JOIN thread t ON t.id = l.thread_id
        JOIN thread_priority tp ON tp.thread_id = t.id
                               AND tp.user_id = requesting_user_id
                               AND tp.priority_id = scope_priority_id
        JOIN priority p ON p.id = tp.priority_id
        WHERE t.embedding IS NOT NULL AND l.thread_id IS NOT NULL
          AND t.archived_at IS NULL
          AND (t.send_at IS NULL OR t.send_at <= now() OR t.created_by = requesting_user_id)
          AND t.contacts && "user".user_contact_ids(requesting_user_id)
          AND (1 - (t.embedding <=> query_embedding::halfvec)) >= similarity_threshold
    ) combined
    ORDER BY combined.similarity DESC
    LIMIT match_limit;
END;
$$;
-- Modify "update_thread_on_note_change" function
CREATE OR REPLACE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- Only act on visible, non-draft, non-held notes. A scheduled note
    -- (future send_at) must not surface the thread or mark it unread; the
    -- release sweep's send_at → NULL update re-fires this trigger at the
    -- moment the note goes live.
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL
        AND (NEW.send_at IS NULL OR NEW.send_at <= now()) THEN
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        IF NEW.access_contacts IS NULL AND NEW.access_groups IS NULL THEN
            -- UNSCOPED note: everyone who can see the thread can see it.
            -- Bump the shared last_note_* columns exactly as before so the
            -- thread re-emits / re-sorts for all recipients.
            UPDATE thread
            SET last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
                last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
                last_note_seq = GREATEST (last_note_seq, NEW.seq),
                -- Max of CONTENT source times only — never seeded with created_at
                -- (import time), so a backfilled note keeps the thread at its
                -- origin time. GREATEST() ignores a NULL activity_base.
                activity_base = GREATEST (activity_base, NEW.source_created_at),
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq
                  OR activity_base IS NULL
                  OR activity_base < NEW.source_created_at);
        ELSE
            -- SCOPED note: do NOT touch the shared last_note_* columns (that
            -- would re-emit the thread for the whole audience, leaking the
            -- existence of a private reply). Instead bump thread_state for
            -- exactly the users who can see this note, so the thread
            -- re-emits / re-sorts / unreads only for them. The author's row
            -- is bumped but kept read; other visible users get read_at = NULL.
            --
            -- "The author" is identified by NEW.author_id (the contact credited
            -- with the note), resolved to its owning user, NOT only by
            -- NEW.created_by. For a reply the user made OUTSIDE Plot (e.g. in
            -- Gmail) and a connector synced back, created_by is the connector's
            -- twist_instance_id while author_id is the user's own linked
            -- contact — so a created_by-only check would mark the author unread
            -- and notify them about their own reply.
            --
            -- bumped_at carries the note's ORIGIN time (source_created_at), NOT
            -- now(). It is the only per-user input to thread_priority.activity_at,
            -- so a live reply (source ~ now) re-surfaces the thread while a
            -- backfilled historical reply sorts at its true time instead of
            -- masquerading as fresh activity at import. The app's separate
            -- Active→Done write sets bumped_at = now() directly; the ON CONFLICT
            -- GREATEST below never lowers such a bump.
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at, last_note_source_created_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   NEW.source_created_at,
                   NEW.source_created_at
            FROM (
                SELECT tp.user_id
                FROM thread_priority tp
                WHERE tp.thread_id = NEW.thread_id
                  AND tp.revoked_at IS NULL
                  AND (
                      tp.user_id = NEW.created_by
                      OR (NEW.access_contacts IS NOT NULL
                          AND NEW.access_contacts && "user".user_contact_ids(tp.user_id))
                      OR (NEW.access_groups IS NOT NULL
                          AND NEW.access_groups && "user".user_group_ids(tp.user_id))
                  )
            ) v
            ON CONFLICT (user_id, thread_id) DO UPDATE
            -- Raise to the note's origin time, never lower an existing (newer)
            -- value — preserves an app-set Active→Done bump and orders by the
            -- latest message this user can actually see.
            SET bumped_at = GREATEST(thread_state.bumped_at, NEW.source_created_at),
                last_note_source_created_at =
                    GREATEST(thread_state.last_note_source_created_at, NEW.source_created_at),
                -- A non-author visible user must see the thread as unread
                -- again; never clobber the author's own read state. The author
                -- is matched by NEW.author_id (its owning user) as well as by
                -- created_by, so a reply synced back from an external system
                -- (created_by = connector, author_id = the user's contact)
                -- does not re-surface as unread for its own author.
                read_at = CASE
                    WHEN thread_state.user_id = NEW.created_by
                         OR NEW.author_id = ANY("user".user_contact_ids(thread_state.user_id))
                    THEN thread_state.read_at
                    ELSE NULL
                END,
                updated_at = now();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    v_priority_id uuid;
    v_created_by uuid;
    -- The actor credited with CAUSING the thread (distinct from v_created_by).
    -- Set on INSERT and filled-only-when-NULL on UPDATE; never re-attributed.
    v_author_id uuid;
    v_twist_id bigint;
    v_is_archived boolean;
    v_chain_next uuid;
    v_chain_hops int;
    -- All linked contact IDs for the calling user. Used to check attestation
    -- and to merge the caller's own contacts into the thread.
    v_user_contacts uuid[];
    -- The caller's primary linked contact (used when we need a single contact
    -- id to record in pending_contacts).
    v_user_primary_contact uuid;
    -- Caller-provided contacts, normalized to uuid[].
    v_input_contacts uuid[];
    -- Working set of contacts that will be written into thread.contacts.
    v_merged_contacts uuid[];
    -- Contacts being promoted out of pending_contacts on this call.
    v_promoted_contacts uuid[];
    -- Input groups normalized.
    v_input_groups uuid[];
    -- Input topic (text) — explicit value or NULL to derive the default.
    v_input_topic text;
    -- Input topic_id — the channel the thread belongs to.
    v_input_topic_id uuid;
    -- Derived topic for INSERT path.
    v_resolved_topic text;
    -- Whether the caller should get a thread_priority row this call.
    v_caller_attested boolean;
BEGIN
    -- Extract identifiers and derived values.
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);

    -- Who CAUSED this thread (distinct from created_by, the acting entity):
    --   1. explicit author_id from the caller (rare),
    --   2. connector/twist runtime supplies the resolved author in p_defaults,
    --   3. app user → their primary contact (user_contact_id is non-null only
    --      for a user, NULL for a twist_instance id),
    --   4. fallback → created_by (a non-connection twist credits itself).
    v_author_id := COALESCE(
        (p_thread   ->> 'author_id')::uuid,
        (p_defaults ->> 'author_id')::uuid,
        "user".user_contact_id(v_created_by),
        v_created_by
    );

    -- Load the caller's linked contacts (used for attestation and merging).
    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    INTO v_user_contacts
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    SELECT uc.contact_id
    INTO v_user_primary_contact
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    ORDER BY uc.primary DESC NULLS LAST, uc.created_at ASC
    LIMIT 1;

    -- Derive twist_id from the caller's twist_instance (never from p_thread:
    -- callers are not allowed to spoof which twist owns a thread).
    IF v_created_by IS NOT NULL AND v_created_by IS DISTINCT FROM user_id THEN
        SELECT ti.twist_id INTO v_twist_id
        FROM twist_instance ti
        WHERE ti.id = v_created_by;
    END IF;

    -- If an id was not supplied, look up an existing thread by (twist_id, key)
    -- across all users. Restrict to non-archived threads so the (twist_id, key)
    -- slot can be reused after a prior thread was fully archived.
    IF v_id IS NULL THEN
        -- Serialize concurrent upserts for the same (twist_id, key) pair.
        -- Without this, two sessions can both see the lookup below miss,
        -- generate different uuidv7() ids, and both INSERT — the second
        -- violates thread_twist_key_unique. The advisory lock is
        -- transaction-scoped, so it releases on COMMIT/ROLLBACK.
        IF v_twist_id IS NOT NULL
           AND COALESCE(p_thread ->> 'key', p_defaults ->> 'key') IS NOT NULL THEN
            PERFORM pg_advisory_xact_lock(
                hashtextextended(
                    'thread_upsert|' ||
                    v_twist_id::text || '|' ||
                    COALESCE(p_thread ->> 'key', p_defaults ->> 'key'),
                    0
                )
            );
        END IF;
        IF (p_thread ? 'key')
            AND v_twist_id IS NOT NULL
            AND (p_thread ->> 'key') IS NOT NULL THEN
            -- Lookup matches archived rows too (drop archived_at filter):
            -- a thread that was merged into another thread keeps its
            -- (twist_id, key) on its archived row. Active row preferred
            -- via NULLS FIRST.
            SELECT t.id, t.merged_into_thread_id
            INTO v_id, v_chain_next
            FROM thread t
            WHERE t.twist_id = v_twist_id
              AND t.key = (p_thread ->> 'key')
            ORDER BY t.archived_at ASC NULLS FIRST
            LIMIT 1;

            -- Follow merged_into_thread_id chain so connector resyncs of
            -- a merge source's external item land on the merged target.
            -- Cap at 10 hops to defend against pathological state.
            v_chain_hops := 0;
            WHILE v_chain_next IS NOT NULL AND v_chain_hops < 10 LOOP
                v_id := v_chain_next;
                SELECT merged_into_thread_id INTO v_chain_next
                FROM thread WHERE id = v_id;
                v_chain_hops := v_chain_hops + 1;
            END LOOP;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;

    -- Resolve priority_id from the caller's existing thread_priority row.
    IF v_priority_id IS NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM thread_priority tp
        WHERE tp.thread_id = v_id
          AND tp.user_id = upsert_thread.user_id;
    END IF;

    -- Fall back to the user's root priority when the given priority isn't
    -- accessible. Priority is per-user organization, not access control, so
    -- we don't hard-fail on cross-user or missing priorities.
    IF v_priority_id IS NULL
       OR NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        SELECT p.id INTO v_priority_id
        FROM public.priority p
        WHERE p.user_id = upsert_thread.user_id
          AND nlevel(p.path) = 1
          AND p.archived_at IS NULL
        ORDER BY p.created_at ASC
        LIMIT 1;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'User has no root priority';
        END IF;
    END IF;

    -- Validate created_by: either the caller or one of their own twist_instances.
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT 1
            FROM twist_instance pt
            WHERE pt.id = v_created_by
              AND pt.owner_id = upsert_thread.user_id
        ) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    -- Load the existing row (if any) — used to satisfy CHECK constraints on
    -- the INSERT-with-ON-CONFLICT path and for merge semantics.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    -- Authorization guard for author_id (mirrors the created_by check above):
    -- a USER caller may only attribute a thread to one of their OWN linked
    -- contacts — never spoof authorship to an arbitrary/other person. The
    -- connector/twist path legitimately credits an EXTERNAL author via
    -- p_defaults.author_id and is trusted here (created_by is the owned
    -- twist_instance, just validated). Only an explicitly-supplied value is
    -- checked; the derived fallback (user_contact_id(user_id)) is always safe.
    -- Existing author_id values are permitted to pass through unchanged.
    IF v_created_by = upsert_thread.user_id
       AND COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid) IS NOT NULL
       AND NOT (COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid) = ANY(v_user_contacts))
       AND (v_existing.id IS NULL OR COALESCE((p_thread ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid) IS DISTINCT FROM v_existing.author_id)
    THEN
        RAISE EXCEPTION 'author_id must be one of the caller''s linked contacts';
    END IF;

    -- Read-only viewer gate. When the thread already exists and the caller
    -- is a user (not a twist) lacking write access, allow only per-user
    -- archive or mute: if archived_at and/or mute_by_thread_id are the only
    -- mutated fields, update thread_priority and return the unchanged
    -- thread. Reject any other metadata change.
    IF v_existing.id IS NOT NULL
       AND v_created_by = upsert_thread.user_id
       AND NOT "user".user_has_thread_write_access(upsert_thread.user_id, v_existing.id)
    THEN
        IF p_thread ? 'archived_at' OR p_thread ? 'mute_by_thread_id' THEN
            UPDATE thread_priority tp
            SET archived_at = CASE
                    WHEN p_thread ? 'archived_at' THEN
                        NULLIF(p_thread ->> 'archived_at', '')::timestamptz
                    ELSE tp.archived_at
                END,
                mute_by_thread_id = CASE
                    WHEN p_thread ? 'mute_by_thread_id' THEN
                        NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
                    ELSE tp.mute_by_thread_id
                END,
                updated_at = now()
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id;
            -- Discard any other fields the caller sent — return unchanged.
            RETURN v_existing;
        END IF;
        RAISE EXCEPTION 'User does not have write access to thread';
    END IF;

    -- If the thread exists, this is effectively an update. We treat the
    -- thread as archived (triggering the insert-path fallthrough for missing
    -- fields) when thread.archived_at is set OR when the caller has no
    -- active (non-archived) thread_priority row. thread_priority.archived_at
    -- is the per-user archive marker.
    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND tp.archived_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );

    -- Normalize caller-provided contacts and groups to uuid[].
    v_input_contacts := CASE
        WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
        ELSE ARRAY[]::uuid[]
    END;

    v_input_groups := CASE
        WHEN p_thread ? 'groups' AND jsonb_typeof(p_thread -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'groups') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'groups' AND jsonb_typeof(p_defaults -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'groups') elem), ARRAY[]::uuid[])
        ELSE COALESCE(v_existing.groups, ARRAY[]::uuid[])
    END;

    v_input_topic := COALESCE(p_thread ->> 'topic', p_defaults ->> 'topic');
    v_input_topic_id := COALESCE((p_thread ->> 'topic_id')::uuid, (p_defaults ->> 'topic_id')::uuid);

    -- On INSERT, derive a default topic when none was provided.
    --
    -- User-authored threads (v_twist_id IS NULL): resolution order
    -- priority.config->>'topic' → priority.id::text (for non-root
    -- priorities, so sibling threads filed in the same sub-priority share a
    -- topic filter for classify_thread_for_user) → groups[1]::text.
    --
    -- Connector/twist threads (v_twist_id IS NOT NULL): leave topic NULL so
    -- the set_thread_topic_from_link_channel trigger keys them by
    -- 'channel:<channel.id>' on link insert. Deriving priority.id here would
    -- pre-empt that trigger (it fires only WHERE topic IS NULL) and collapse
    -- every channel filed under one sub-priority into a single coarse topic,
    -- which made topic_shortcircuit funnel unrelated threads into one
    -- priority. Connector threads must be keyed by their channel, not by the
    -- priority the classifier happened to pick at creation.
    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        IF v_input_topic_id IS NOT NULL THEN
            -- A topic-addressed thread routes by its channel, stable across
            -- the whole stream, so the classifier topic short-circuit groups
            -- the user's moves of any one thread onto all the others.
            v_resolved_topic := 'topic:' || v_input_topic_id::text;
        ELSIF v_twist_id IS NULL THEN
            SELECT
                COALESCE(
                    p.config ->> 'topic',
                    CASE WHEN nlevel(p.path) > 1 THEN p.id::text END
                )
            INTO v_resolved_topic
            FROM public.priority p
            WHERE p.id = v_priority_id;

            IF v_resolved_topic IS NULL AND cardinality(v_input_groups) > 0 THEN
                v_resolved_topic := v_input_groups[1]::text;
            END IF;
        END IF;
    ELSE
        v_resolved_topic := v_input_topic;
    END IF;

    -- Attestation check (determined BEFORE we mutate thread.contacts so a
    -- caller can't self-attest by adding an OTHER user's contact in the same
    -- call):
    --   - On insert: creator is always trusted with the initial contact list.
    --   - On update: caller is attested iff one of their linked contacts was
    --     already in thread.contacts before this call (or in pending_contacts,
    --     in which case this call promotes them).
    --   - User-created threads (v_created_by = user_id and no twist_id)
    --     bypass attestation — user flows go through share_thread.
    --   - Sync via the caller's OWN twist_instance (v_created_by <> user_id,
    --     already validated above as a twist_instance owned by the caller) is
    --     itself the attestation: the caller's own connector fetched this item
    --     with the caller's credentials, which independently confirms source
    --     access — exactly the model the file_thread_priority_peers trigger
    --     documents ("peers gain visibility only via their own connector's
    --     upsert_thread call"). Without this, the SECOND user to sync a
    --     cross-user-shared connector thread (same (twist_id, key), created by
    --     another user's instance — e.g. two Plot users syncing the same GitHub
    --     repo) is never present in thread.contacts, so they never get a
    --     thread_priority filing and the subsequent upsert_link raises "User
    --     does not have access to this thread", breaking their entire sync of
    --     shared items (PostHog 019f0730). This attests only the CALLER
    --     themselves; peers are still gated (file_thread_priority_peers skips
    --     twist-authored threads), so it does NOT reopen the rogue-connector
    --     admission hole the attestation model guards against.
    v_caller_attested := (v_existing.id IS NULL)
        OR (v_created_by = upsert_thread.user_id AND v_twist_id IS NULL)
        OR (v_user_contacts && COALESCE(v_existing.contacts, ARRAY[]::uuid[]))
        OR (v_created_by IS DISTINCT FROM upsert_thread.user_id);

    -- Decide contact merge policy based on attestation.
    IF v_caller_attested THEN
        -- Trusted caller: union existing and input contacts. If none of the
        -- caller's linked contacts are already represented, add their
        -- primary linked contact so the caller has visibility. We do NOT
        -- merge every linked contact of the caller — otherwise a user with
        -- multiple linked identities (work + personal email, etc.) shows
        -- up multiple times to every other viewer of the thread.
        -- ORDER BY x makes the array order deterministic so that downstream
        -- consumers (the user_contact INSERT below and the
        -- sync_user_contact_for_thread_contacts trigger) acquire row locks
        -- in a stable order. Without it, two concurrent upserts of threads
        -- with overlapping contacts can lock the same (user_id, contact_id)
        -- pairs in different orders and deadlock.
        SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
        INTO v_merged_contacts
        FROM unnest(
            COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            || v_input_contacts
        ) AS x;

        IF v_user_primary_contact IS NOT NULL
           AND NOT (v_user_contacts && v_merged_contacts) THEN
            v_merged_contacts := v_merged_contacts || ARRAY[v_user_primary_contact];
        END IF;
    ELSE
        -- Untrusted caller: thread.contacts cannot be extended by this
        -- sync. The caller's primary linked contact lands in pending_contacts
        -- below (in the post-upsert branch).
        v_merged_contacts := COALESCE(v_existing.contacts, ARRAY[]::uuid[]);
    END IF;

    -- Identify contacts being promoted from pending_contacts on this call.
    -- Only a trusted (attested) caller can promote — otherwise a rogue
    -- instance could claim an attested user and push them into contacts.
    IF v_caller_attested
       AND v_existing.pending_contacts IS NOT NULL
       AND cardinality(v_existing.pending_contacts) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT p ORDER BY p), ARRAY[]::uuid[])
        INTO v_promoted_contacts
        FROM unnest(v_existing.pending_contacts) AS p
        WHERE p = ANY(v_input_contacts);
        -- Promoted contacts also go into the merged contacts list.
        IF cardinality(v_promoted_contacts) > 0 THEN
            SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
            INTO v_merged_contacts
            FROM unnest(v_merged_contacts || v_promoted_contacts) AS x;
        END IF;
    ELSE
        v_promoted_contacts := ARRAY[]::uuid[];
    END IF;

    -- Perform the upsert. twist_id is set only on the insert path; the update
    -- path preserves thread.twist_id so first-creator wins.
    INSERT INTO thread (
        id, created_by, author_id, title, preview, updated_by, sync_depth, contacts, contact_meta, groups, topic,
        draft, key, icon, twist_id, pending_contacts, team_id, embedding, assignee_id, topic_id, facets, send_at
    )
    VALUES (
        v_id,
        v_created_by,
        v_author_id,
        COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
        COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
        COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
        COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
        v_merged_contacts,
        -- Additive merge of caller-provided contact_meta (entries keyed by
        -- contact_id) onto whatever the row already has. Keys that match
        -- contacts being removed below are not stripped here; that's the
        -- POST /thread/:id/share path's job.
        -- Only merge when the caller actually provided an object. A literal
        -- JSON null (`"contact_meta": null`, which clients send for "no meta")
        -- is a JSONB 'null', not SQL NULL, so COALESCE(..., '{}') won't catch
        -- it — and `'{}'::jsonb || 'null'::jsonb` coerces both operands to
        -- single-element arrays and yields `[{}, null]`, corrupting the column
        -- (it must stay an object keyed by contact_id). Guard on jsonb_typeof
        -- so null/array/scalar inputs become a no-op merge.
        COALESCE(v_existing.contact_meta, '{}'::jsonb)
            || (CASE WHEN jsonb_typeof(p_thread -> 'contact_meta') = 'object'
                    THEN p_thread -> 'contact_meta'
                    ELSE '{}'::jsonb END),
        v_input_groups,
        v_resolved_topic,
        COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
        COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
        COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon),
        v_twist_id,
        -- pending_contacts on the INSERT path starts empty; entries are added
        -- below only when the caller cannot attest themselves.
        ARRAY[]::uuid[],
        -- team_id: explicit from the caller (user-composed Note/Chat) or
        -- NULL for connector threads, which set_thread_team_and_external
        -- then defaults from the creating twist_instance.team_id.
        COALESCE((p_thread ->> 'team_id')::bigint, (p_defaults ->> 'team_id')::bigint),
        -- Content embedding for focus-matching / classification. The caller
        -- (prepareThreadForDb) computes it and passes it in p_defaults.embedding
        -- as the halfvec text form ("[0.1,...]"). Historically this column was
        -- omitted from the INSERT list, so every source-based (connector/twist)
        -- thread was created with a NULL embedding and never surfaced in
        -- "find matching threads".
        NULLIF(COALESCE(p_thread ->> 'embedding', p_defaults ->> 'embedding'), '')::halfvec,
        -- Thread-level assignee. Explicit caller value wins; otherwise default;
        -- otherwise preserve the existing row's assignee (archived-refile path).
        -- For connector threads the mirror trigger owns this column, so
        -- connectors that never send assignee_id leave it untouched here.
        COALESCE((p_thread ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_existing.assignee_id),
        -- topic_id: the channel this thread belongs to. Written on INSERT;
        -- on update it is preserved unless the payload includes 'topic_id'
        -- (or the thread is re-filed from archive). See the ON CONFLICT clause.
        v_input_topic_id,
        -- Intrinsic facets (format/automation/reach) supplied by the connector
        -- via p_defaults.facets. Server-only classifier signal; never synced.
        COALESCE(p_thread -> 'facets', p_defaults -> 'facets'),
        -- Scheduled-send hold for a thread composed with a scheduled first
        -- note. Only user clients set this; connectors never do.
        (p_thread ->> 'send_at')::timestamptz
    )
    ON CONFLICT (id)
        DO UPDATE SET
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            -- Immutable attribution: set once, never overwritten. The BEFORE UPDATE
            -- trigger protect_thread_created_by enforces this. A later sync
            -- (or the connector backfill sweep) may fill a NULL author, but can
            -- never re-attribute a thread that already has an author.
            author_id = COALESCE(thread.author_id, v_author_id),
            -- Additive contact merge. The union already includes existing +
            -- input + caller's own linked contacts.
            contacts = v_merged_contacts,
            -- Additive contact_meta merge: caller-provided entries (keyed by
            -- contact_id) override existing entries for the same contact;
            -- entries for contacts the caller didn't mention are preserved.
            -- Per-contact role changes / removals go through share_thread
            -- (POST /thread/:id/share), not through upsert_thread.
            -- jsonb_typeof guard: a literal `"contact_meta": null` is a JSONB
            -- 'null' (not SQL NULL), so it slips past COALESCE and the `||`
            -- merge would coerce object+null into `[{}, null]`, corrupting the
            -- column. Only merge real objects; null/array/scalar → no-op.
            contact_meta = CASE WHEN p_thread ? 'contact_meta' THEN
                COALESCE(thread.contact_meta, '{}'::jsonb)
                    || (CASE WHEN jsonb_typeof(p_thread -> 'contact_meta') = 'object'
                            THEN p_thread -> 'contact_meta'
                            ELSE '{}'::jsonb END)
            ELSE
                thread.contact_meta
            END,
            groups = CASE WHEN v_is_archived THEN
                v_input_groups
            ELSE
                CASE WHEN p_thread ? 'groups' THEN
                    v_input_groups
                ELSE
                    thread.groups
                END
            END,
            topic = CASE WHEN v_is_archived THEN
                v_resolved_topic
            ELSE
                CASE WHEN p_thread ? 'topic' THEN
                    v_input_topic
                ELSE
                    thread.topic
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            -- Present-key semantics: a client setting an assignee sends the
            -- key explicitly. Connectors never send assignee_id, so the mirror
            -- trigger remains the owner of connector-thread assignment.
            assignee_id = CASE WHEN p_thread ? 'assignee_id' THEN
                (p_thread ->> 'assignee_id')::uuid
            ELSE
                thread.assignee_id
            END,
            -- Never let an upsert CLEAR a scheduled-send hold: release is the
            -- sweep's job and clients cancel by archiving. COALESCE keeps the
            -- hold when a (possibly old) client omits send_at.
            send_at = COALESCE((p_thread ->> 'send_at')::timestamptz, thread.send_at),
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            -- Immutable identity: first creator wins. We do NOT overwrite
            -- thread.created_by or thread.twist_id on update.
            -- Remove promoted contacts from pending_contacts.
            pending_contacts = CASE
                WHEN cardinality(v_promoted_contacts) > 0 THEN
                    COALESCE((
                        SELECT array_agg(p)
                        FROM unnest(thread.pending_contacts) AS p
                        WHERE NOT (p = ANY(v_promoted_contacts))
                    ), ARRAY[]::uuid[])
                ELSE
                    thread.pending_contacts
            END,
            -- Persist/refresh the content embedding. On a normal update we keep
            -- the existing embedding unless the caller explicitly passes a new
            -- one in p_thread (so frequent connector re-syncs don't churn it);
            -- on the archived-refile path (treated like an insert) we repopulate
            -- from the caller, preserving the existing value if none was
            -- supplied. We never wipe an embedding we already have.
            embedding = CASE
                WHEN v_is_archived THEN
                    COALESCE(
                        NULLIF(COALESCE(p_thread ->> 'embedding', p_defaults ->> 'embedding'), '')::halfvec,
                        thread.embedding
                    )
                ELSE
                    CASE WHEN p_thread ? 'embedding'
                        THEN NULLIF(p_thread ->> 'embedding', '')::halfvec
                        ELSE thread.embedding
                    END
            END,
            topic_id = CASE WHEN v_is_archived THEN
                v_input_topic_id
            ELSE
                CASE WHEN p_thread ? 'topic_id' THEN v_input_topic_id ELSE thread.topic_id END
            END
            ,
            -- Fill facets only when the row has none yet (connector backfill on
            -- re-sync). Never churn an existing value; never wipe to null.
            facets = COALESCE(thread.facets, EXCLUDED.facets)
        RETURNING * INTO v_result;

    -- Attestation was already computed before the merge (see above). If the
    -- caller was attested, they file their own thread_priority row. Otherwise
    -- we record their primary contact in pending_contacts and defer filing.
    --
    -- LOCK ORDER INVARIANT — DO NOT BREAK:
    --   By the time we reach this INSERT, the thread INSERT/UPDATE at line
    --   359 has already fired the FOR EACH STATEMENT sync_user_for_thread
    --   trigger, which inserts user_sync rows for every user with a
    --   thread_priority on this thread. So our acquisition order is:
    --      thread row (line 359) → user_sync (statement trigger)
    --      → thread_priority (THIS INSERT) → user_sync (re-acquired via
    --        sync_user_for_thread_priority statement trigger; already held).
    --   Any other write path that touches both thread_priority and user_sync
    --   for the same thread MUST acquire them in the same relative order
    --   (thread → user_sync → thread_priority), or it will deadlock with
    --   this function under concurrency. See the matching invariant block
    --   in libs/db/schema/95-triggers/18-thread_topic_from_channel.sql.
    IF v_caller_attested THEN
        -- Normal path: the caller can file the thread under their priority.
        -- Stamp applied_default_channel_id when the chosen priority matches
        -- the thread's channel default, but only when the caller did not
        -- pass an explicit priority_id (an explicit pick is never a default).
        INSERT INTO thread_priority (
            thread_id, user_id, priority_id, applied_default_channel_id,
            mute_by_thread_id
        )
        VALUES (
            v_result.id,
            upsert_thread.user_id,
            v_priority_id,
            CASE
                WHEN p_thread ? 'priority_id' THEN NULL
                ELSE public.channel_default_marker (
                    upsert_thread.user_id, v_result.id, v_priority_id
                )
            END,
            NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
        )
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET
            priority_id = CASE
                WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
                WHEN v_is_archived THEN EXCLUDED.priority_id
                ELSE thread_priority.priority_id
            END,
            -- An explicit caller priority_id is not a default placement.
            -- Preserve the existing marker otherwise.
            applied_default_channel_id = CASE
                WHEN p_thread ? 'priority_id' THEN NULL
                ELSE thread_priority.applied_default_channel_id
            END,
            -- Un-archive on a legitimate re-file.
            archived_at = NULL,
            -- Mute flag: explicit payload value wins; otherwise preserve.
            -- The clear path (broom toggled off) is handled by
            -- "user".clear_mute, invoked by the API after upsert.
            mute_by_thread_id = CASE
                WHEN p_thread ? 'mute_by_thread_id' THEN
                    NULLIF(p_thread ->> 'mute_by_thread_id', '')::uuid
                ELSE thread_priority.mute_by_thread_id
            END,
            updated_at = now();
    ELSE
        -- Attestation not yet established. Record the caller's primary
        -- contact in pending_contacts so a subsequent attester can promote
        -- them. Do not create a thread_priority row — the caller will not
        -- see this thread yet.
        IF v_user_primary_contact IS NOT NULL THEN
            UPDATE thread
            SET pending_contacts = (
                SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
                FROM unnest(COALESCE(pending_contacts, ARRAY[]::uuid[]) || ARRAY[v_user_primary_contact]) AS x
            )
            WHERE id = v_result.id
              AND NOT (v_user_primary_contact = ANY(COALESCE(pending_contacts, ARRAY[]::uuid[])))
              AND NOT (v_user_primary_contact = ANY(COALESCE(contacts, ARRAY[]::uuid[])));
            -- Refresh v_result so the returned row reflects the updated pending_contacts.
            SELECT * INTO v_result FROM thread WHERE id = v_result.id;
        END IF;
    END IF;

    -- Promote pending contacts that the caller has now attested: create
    -- pending thread_priority rows for each linked user whose contact was
    -- just moved out of pending_contacts. The consumer Worker picks each
    -- peer's priority once the API enqueues the ClassifyJobs after the
    -- transaction commits. applied_default_channel_id is left NULL here —
    -- the consumer recomputes via channel_default_marker when it writes
    -- the final priority.
    IF cardinality(v_promoted_contacts) > 0 THEN
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT v_result.id, peer.user_id, NULL::uuid, now()
        FROM (
            SELECT DISTINCT uc.user_id
            FROM unnest(v_promoted_contacts) AS arr(contact_id)
            JOIN user_contact uc
              ON uc.contact_id = arr.contact_id
             AND uc.linked = TRUE
             AND uc.archived_at IS NULL
            WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
        ) peer
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET archived_at = NULL,
                      -- Mark for re-classification on re-attestation.
                      classify_at = COALESCE(thread_priority.classify_at, now()),
                      updated_at = now();

        INSERT INTO thread_state (user_id, thread_id)
        SELECT peer.user_id, v_result.id
        FROM (
            SELECT DISTINCT uc.user_id
            FROM unnest(v_promoted_contacts) AS arr(contact_id)
            JOIN user_contact uc
              ON uc.contact_id = arr.contact_id
             AND uc.linked = TRUE
             AND uc.archived_at IS NULL
            WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
        ) peer
        ON CONFLICT ON CONSTRAINT thread_state_pkey DO NOTHING;
    END IF;

    -- Re-mark peer thread_priority rows pending on INITIAL creation. The
    -- file_thread_priority_peers / file_thread_priority_for_group_members
    -- triggers wrote pending markers; this block additionally re-marks any
    -- peer rows whose cross-user keyed-priority signal only becomes
    -- available now that the author's row has been inserted. Skipped on
    -- UPDATE because the triggers handle UPDATE OF contacts / groups
    -- correctly and we don't want to disrupt peers who organized on their
    -- own side.
    IF v_existing.id IS NULL THEN
        UPDATE public.thread_priority tp
        SET classify_at = COALESCE(tp.classify_at, now()),
            updated_at = now()
        WHERE tp.thread_id = v_result.id
          AND tp.user_id IS DISTINCT FROM upsert_thread.user_id
          AND tp.user_moved IS NOT TRUE
          AND tp.archived_at IS NULL;
    END IF;

    -- Ensure the calling user has user_contact rows for all external
    -- contacts on this thread so they appear as actors in the app.
    -- ORDER BY arr.contact_id locks (user_id, contact_id) rows in a stable
    -- order across concurrent transactions. Without it, two parallel
    -- upsert_thread calls with overlapping contacts (e.g. two Gmail
    -- webhooks arriving in close succession) can attempt to take the same
    -- user_contact row locks in different orders and deadlock.
    IF v_result.contacts IS NOT NULL AND cardinality(v_result.contacts) > 0 THEN
        INSERT INTO user_contact (user_id, contact_id, linked, source)
        SELECT upsert_thread.user_id, arr.contact_id, false, 'thread'
        FROM unnest(v_result.contacts) AS arr(contact_id)
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
        ORDER BY arr.contact_id
        ON CONFLICT ON CONSTRAINT user_contact_pkey DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;
-- Create "note_redacted" view
CREATE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "send_at",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "cta",
  "delivery_error",
  "mentions",
  "re_note_id",
  "merged_from_thread_id",
  "section_key",
  "section_label",
  "section_position",
  "item_position"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::timestamp with time zone AS send_at,
    NULL::uuid[] AS access_contacts,
    NULL::uuid[] AS access_groups,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::jsonb AS cta,
    NULL::jsonb AS delivery_error,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id,
    NULL::text AS section_key,
    NULL::text AS section_label,
    NULL::text AS section_position,
    NULL::text AS item_position
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.send_at IS NULL OR n.send_at <= now()) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.send_at IS NULL OR a.send_at <= now()) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND n.created_by <> tp.user_id AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL) AND NOT (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND NOT (a.dropped_contacts IS NOT NULL AND cardinality(a.dropped_contacts) > 0 AND a.dropped_contacts && "user".user_contact_ids(tp.user_id));
-- Drop "upsert_note" function
DROP FUNCTION "user"."upsert_note" (uuid, uuid, uuid, uuid, integer, timestamptz, uuid, boolean, uuid[], uuid[], text, jsonb, uuid[], uuid, timestamptz, text, uuid);
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_access_groups" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid, "p_send_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_existing_thread_id uuid;
    v_row note;
BEGIN
    -- If p_id refers to an existing note, verify the caller has access to
    -- its CURRENT thread before allowing the upsert. Without this, anyone
    -- who learns a note's UUID (e.g. via user.note_redacted after losing
    -- visibility) could move the note onto a thread they own and rewrite
    -- its content / archived_at while bypassing the original thread's
    -- access controls. The user.note_redacted view exposes note ids and
    -- thread_ids for notes that became invisible, so this attack vector
    -- is reachable from normal sync traffic.
    IF p_id IS NOT NULL THEN
        SELECT thread_id INTO v_existing_thread_id FROM note WHERE id = p_id;
        IF v_existing_thread_id IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM thread_priority tp
                WHERE tp.thread_id = v_existing_thread_id
                  AND tp.user_id = upsert_note.user_id
            ) THEN
                RAISE EXCEPTION 'Note not found';
            END IF;
        END IF;
    END IF;

    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_note.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Visibility is established by the thread_priority lookup above. The
    -- read-only viewer gate below uses user_has_thread_write_access(), which
    -- accepts write access via contacts OR non-announce group membership OR
    -- admin of an announce group, and forces announce-only viewers down the
    -- access_contacts path. Don't add a stricter contacts-only check here —
    -- it silently strands notes from users whose write access comes via
    -- group membership rather than direct contact in thread.contacts.

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
    END IF;

    -- Read-only viewer gate. A user who reaches the thread only via an
    -- announce group (no write access) may post only scoped notes they
    -- author, and the scope is bounded to the thread's contacts plus its
    -- non-announce groups (announce groups where they are not an admin are
    -- excluded). This is the server-side enforcement of the reply rule and
    -- prevents a viewer from broadcasting back to the announce audience.
    IF v_created_by = upsert_note.user_id
       AND NOT "user".user_has_thread_write_access(upsert_note.user_id, p_thread_id)
    THEN
        -- Must be scoped (no public notes).
        IF p_access_contacts IS NULL AND p_access_groups IS NULL THEN
            RAISE EXCEPTION 'Read-only viewers must scope notes via access_contacts or access_groups';
        END IF;

        -- access_contacts ⊆ thread.contacts ∪ caller's own linked contacts.
        IF p_access_contacts IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_contacts) AS c(id)
            WHERE c.id <> ALL (
                COALESCE((SELECT contacts FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[])
                || "user".user_contact_ids(upsert_note.user_id)
            )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to thread contacts';
        END IF;

        -- access_groups ⊆ thread.groups, excluding announce groups where the
        -- caller is not an admin; reject non-existent or archived groups.
        IF p_access_groups IS NOT NULL AND EXISTS (
            SELECT 1
            FROM unnest(p_access_groups) AS g(id)
            LEFT JOIN "group" gr ON gr.id = g.id
            WHERE
                gr.id IS NULL                       -- non-existent group
                OR gr.archived_at IS NOT NULL       -- archived group
                OR g.id <> ALL (COALESCE((SELECT groups FROM thread WHERE id = p_thread_id), ARRAY[]::uuid[]))
                OR (
                    gr.type = 'announce'
                    AND NOT EXISTS (
                        SELECT 1 FROM group_admin ga
                        WHERE ga.group_id = g.id AND ga.user_id = upsert_note.user_id
                    )
                )
        ) THEN
            RAISE EXCEPTION 'Read-only viewers may only scope notes to non-announce thread groups';
        END IF;

        -- May not edit another author's note.
        IF p_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM note
            WHERE id = p_id
              AND author_id IS DISTINCT FROM v_author_id
        ) THEN
            RAISE EXCEPTION 'User cannot edit another author''s note';
        END IF;
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id, send_at)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id, p_send_at)
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                access_groups = EXCLUDED.access_groups,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                -- Never let an upsert CLEAR a hold: clients cancel a schedule
                -- by archiving the note, and release is the sweep's job. An
                -- old client editing a held note omits send_at — COALESCE
                -- keeps the hold instead of firing the note immediately.
                send_at = COALESCE(EXCLUDED.send_at, note.send_at),
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, access_groups, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id, send_at)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_access_groups, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id, p_send_at)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                access_groups = EXCLUDED.access_groups,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                -- COALESCE: see the keyed path above — an upsert may set or
                -- keep a hold but never clear one.
                send_at = COALESCE(EXCLUDED.send_at, note.send_at),
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "send_at",
  "access_contacts",
  "access_groups",
  "content",
  "actions",
  "cta",
  "delivery_error",
  "mentions",
  "re_note_id",
  "merged_from_thread_id",
  "section_key",
  "section_label",
  "section_position",
  "item_position"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.send_at,
    n.access_contacts,
    n.access_groups,
    n.content,
    n.actions,
    n.cta,
    n.delivery_error,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id,
    n.section_key,
    n.section_label,
    n.section_position,
    n.item_position
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (n.send_at IS NULL OR n.send_at <= now() OR n.created_by = tp.user_id) AND (n.created_by = tp.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id)) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.send_at IS NULL OR a.send_at <= now() OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id))));
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "send_at",
  "contacts",
  "contact_meta",
  "groups",
  "team_id",
  "topic",
  "topic_id",
  "title",
  "preview",
  "icon",
  "author_id",
  "assignee_id",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.send_at,
    a.contacts,
    a.contact_meta,
    a.groups,
    a.team_id,
    a.topic,
    a.topic_id,
    a.title,
    a.preview,
    a.icon,
    a.author_id,
    a.assignee_id,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.mute_by_thread_id,
    a.last_note_created_at,
    GREATEST(a.last_note_source_created_at, ts.last_note_source_created_at) AS last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    tp.activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
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
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.send_at IS NULL OR a.send_at <= now() OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (a.team_id IS NULL OR a.external_contacts && "user".user_contact_ids(tp.user_id) OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = a.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Create "thread_redacted" view
CREATE VIEW "user"."thread_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "send_at",
  "contacts",
  "contact_meta",
  "groups",
  "team_id",
  "topic",
  "topic_id",
  "title",
  "preview",
  "icon",
  "author_id",
  "assignee_id",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    tp.revoked_at AS updated_at,
    tp.seq,
    a.updated_by,
    tp.revoked_at AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    NULL::timestamp with time zone AS send_at,
    ARRAY[]::uuid[] AS contacts,
    '{}'::jsonb AS contact_meta,
    ARRAY[]::uuid[] AS groups,
    NULL::bigint AS team_id,
    NULL::text AS topic,
    NULL::uuid AS topic_id,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::text AS icon,
    NULL::uuid AS author_id,
    NULL::uuid AS assignee_id,
    NULL::uuid AS merged_into_thread_id,
    false AS has_embedding,
    NULL::uuid AS mute_by_thread_id,
    NULL::timestamp with time zone AS last_note_created_at,
    NULL::timestamp with time zone AS last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    false AS active,
    NULL::boolean AS urgent,
    NULL::double precision AS state_order,
    NULL::daterange AS state_on,
    NULL::tstzrange AS state_at,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at,
    true AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
  WHERE tp.revoked_at IS NOT NULL AND (a.send_at IS NULL OR a.send_at <= now());
-- Create "note_reactions" view
CREATE VIEW "user"."note_reactions" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "reactions"
) AS SELECT ua.user_id,
    n.id,
    nr.updated_at,
    nr.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nr.reactions
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nr_1.emoji,
                    jsonb_agg(nr_1.actor_id ORDER BY nr_1.actor_id) FILTER (WHERE nr_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nr_1.archived_at, nr_1.updated_at)) AS updated_at,
                    max(nr_1.seq) AS seq
                   FROM public.note_reaction nr_1
                  WHERE nr_1.note_id = n.id
                  GROUP BY nr_1.emoji) sq
         HAVING count(*) > 0) nr ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.send_at IS NULL OR n.send_at <= now() OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nt_1.tag_id,
                    jsonb_agg(nt_1.actor_id ORDER BY nt_1.actor_id) FILTER (WHERE nt_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nt_1.archived_at, nt_1.updated_at)) AS updated_at,
                    max(nt_1.seq) AS seq
                   FROM public.note_tag nt_1
                  WHERE nt_1.note_id = n.id
                  GROUP BY nt_1.tag_id) sq
         HAVING count(*) > 0) nt ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.send_at IS NULL OR n.send_at <= now() OR n.created_by = ua.user_id) AND (n.created_by = ua.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(ua.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(ua.user_id));
-- Create "thread_reactions" view
CREATE VIEW "user"."thread_reactions" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "reactions"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tr.occurrence,
    tr.updated_at,
    tr.seq,
    ua.priority_id,
    ua.priority_path,
    tr.reactions
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT tr_1.occurrence,
                    tr_1.emoji,
                    jsonb_agg(tr_1.actor_id) FILTER (WHERE tr_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(tr_1.archived_at, tr_1.updated_at)) AS updated_at,
                    max(tr_1.seq) AS seq
                   FROM public.thread_reaction tr_1
                  WHERE tr_1.thread_id = ua.id
                  GROUP BY tr_1.occurrence, tr_1.emoji) sq
          GROUP BY sq.occurrence) tr ON true;
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    tt.seq,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                    max(at.seq) AS seq
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "author_id",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "dropped_contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "assignee_id",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "topic_id",
  "pending_contacts",
  "contact_meta",
  "pending_create_link",
  "facets",
  "send_at",
  "seq",
  "last_note_seq",
  "merged_into_thread_id",
  "team_id",
  "external_contacts",
  "activity_base"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    author_id,
    updated_by,
    archived_at,
    draft,
    contacts,
    dropped_contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    assignee_id,
    groups,
    topic,
    embedding,
    twist_id,
    topic_id,
    pending_contacts,
    contact_meta,
    pending_create_link,
    facets,
    send_at,
    seq,
    last_note_seq,
    merged_into_thread_id,
    team_id,
    external_contacts,
    activity_base
   FROM public.thread a;
-- Modify "twist_instance_channel_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "link_id",
  "link_source",
  "link_title",
  "link_type",
  "link_meta",
  "link_channel_id",
  "link_source_url",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "author_name",
  "author_type",
  "tags",
  "section_key",
  "section_label",
  "section_position",
  "item_position"
) AS SELECT DISTINCT ON (ptc.twist_instance_id, n.id) ptc.twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    tp.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    n.section_key,
    n.section_label,
    n.section_position,
    n.item_position
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.archived_at IS NULL AND (n.send_at IS NULL OR n.send_at <= now()) AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;
-- Modify "twist_instance_note_create" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags",
  "section_key",
  "section_label",
  "section_position",
  "item_position"
) AS SELECT pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    n.section_key,
    n.section_label,
    n.section_position,
    n.item_position
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.archived_at IS NULL AND (n.send_at IS NULL OR n.send_at <= now()) AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY n.created_at;
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    true AS unread,
    max(ts.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.send_at IS NULL OR a.send_at <= now() OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (a.team_id IS NULL OR a.external_contacts && "user".user_contact_ids(tp.user_id) OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = a.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)))
     JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id AND ts.read_at IS NULL AND (ts.importance >= 50 OR ts.urgent = true)
  GROUP BY tp.user_id, ("user".effective_priority_id(tp.priority_id, tp.user_id));
