-- Create "sync_user_contact_for_thread_contacts" function
CREATE FUNCTION "public"."sync_user_contact_for_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    INSERT INTO user_contact (user_id, contact_id, linked, source)
    SELECT tp.user_id, arr.contact_id, false, 'thread'
    FROM thread_priority tp
    CROSS JOIN unnest(NEW.contacts) AS arr(contact_id)
    WHERE tp.thread_id = NEW.id
      AND EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
    ON CONFLICT (user_id, contact_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Create trigger "sync_user_contact_for_thread_contacts"
CREATE TRIGGER "sync_user_contact_for_thread_contacts" AFTER INSERT OR UPDATE OF "contacts" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."sync_user_contact_for_thread_contacts"();
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
    -- Author's own contact IDs — merged into contacts so the author
    -- always passes the visibility filter (t.contacts && user_contact_ids()).
    v_user_contacts uuid[];
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Fetch the calling user's linked contact IDs so they can be merged
    -- into thread.contacts below, ensuring the author always satisfies
    -- the visibility filter (t.contacts && user_contact_ids(user_id)).
    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    INTO v_user_contacts
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + creator
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_created_by IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND created_by = v_created_by;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread_priority row for this user
    IF v_priority_id IS NULL THEN
        SELECT
            tp.priority_id INTO v_priority_id
        FROM
            thread_priority tp
        WHERE
            tp.thread_id = v_id
            AND tp.user_id = upsert_thread.user_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access: user must own the target priority
    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                twist_instance pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;
    -- Fetch the existing thread row (if any) so partial updates can fall
    -- back to current values. Postgres evaluates CHECK constraints on the
    -- INSERT values before ON CONFLICT DO UPDATE kicks in, so the VALUES
    -- clause below must already satisfy the constraints — which means the
    -- INSERT must carry the existing row's values for any field the caller
    -- omitted.
    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );
    -- Perform the upsert and return the full row.
    -- INSERT values fall through p_thread → p_defaults → v_existing so
    -- that on the UPDATE path the INSERT satisfies CHECK constraints even
    -- when the caller omits fields like title.
    INSERT INTO thread (id, created_by, title, preview, updated_by, sync_depth, contacts, topics, draft, key, icon)
        VALUES (
            v_id,
            v_created_by,
            COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
            COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
            COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
            COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
            (SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[]) FROM unnest(
                CASE
                    WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                        COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                    WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                        COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                    ELSE COALESCE(v_existing.contacts, ARRAY[]::uuid[])
                END || v_user_contacts
            ) x),
            CASE
                WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE COALESCE(v_existing.topics, ARRAY[]::uuid[])
            END,
            COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
            COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
            COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
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
            contacts = (SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[]) FROM unnest(
                CASE WHEN v_is_archived THEN
                    CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                        COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                    WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
                        COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
                    ELSE thread.contacts END
                ELSE
                    CASE WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
                        COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
                    ELSE
                        thread.contacts
                    END
                END || v_user_contacts
            ) x),
            topics = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'topics' AND jsonb_typeof(p_defaults -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'topics') elem), ARRAY[]::uuid[])
                ELSE thread.topics END
            ELSE
                CASE WHEN p_thread ? 'topics' AND jsonb_typeof(p_thread -> 'topics') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'topics') elem), ARRAY[]::uuid[])
                ELSE
                    thread.topics
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
            created_by = v_created_by
        RETURNING
            * INTO v_result;

    -- Upsert the calling user's thread_priority row. On update, only
    -- change priority_id if the caller explicitly provided one.
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    VALUES (v_result.id, upsert_thread.user_id, v_priority_id)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        priority_id = CASE
            WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
            WHEN v_is_archived THEN EXCLUDED.priority_id
            ELSE thread_priority.priority_id
        END,
        updated_at = now();

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    -- Ensure the calling user has user_contact rows for all external
    -- contacts on this thread so they appear as actors in the app.
    IF v_result.contacts IS NOT NULL AND cardinality(v_result.contacts) > 0 THEN
        INSERT INTO user_contact (user_id, contact_id, linked, source)
        SELECT upsert_thread.user_id, arr.contact_id, false, 'thread'
        FROM unnest(v_result.contacts) AS arr(contact_id)
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
        ON CONFLICT (user_id, contact_id) DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;
-- Drop "actor" view
DROP VIEW "user"."actor";
-- Drop "priority_actor" view
DROP VIEW "user"."priority_actor";
-- Create "actor" view
CREATE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self"
) AS SELECT uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c_1
          WHERE c_1.id = a.id AND c_1.user_id = uc.user_id)) AS self
   FROM public.user_contact uc
     JOIN public.contact c ON c.id = uc.contact_id
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NULL OR c."primary" = true
UNION ALL
 SELECT uc_primary.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    c.user_id = uc_primary.user_id AS self
   FROM public.contact c
     JOIN public.actor a ON a.id = c.id
     JOIN public.contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
     JOIN public.user_contact uc_primary ON uc_primary.contact_id = c_primary.id
  WHERE c."primary" = false
UNION ALL
 SELECT u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self
   FROM public."user" u
     JOIN public.twist_instance pt ON pt.owner_id = u.id
     JOIN public.actor a ON a.id = pt.id;
-- Backfill: ensure user_contact rows exist for all contacts on existing threads
INSERT INTO user_contact (user_id, contact_id, linked, source)
SELECT DISTINCT tp.user_id, arr.contact_id, false, 'thread'
FROM thread t
CROSS JOIN unnest(t.contacts) AS arr(contact_id)
JOIN thread_priority tp ON tp.thread_id = t.id
WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
ON CONFLICT (user_id, contact_id) DO NOTHING;
