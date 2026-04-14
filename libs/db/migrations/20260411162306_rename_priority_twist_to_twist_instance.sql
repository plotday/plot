-- =====================================================================
-- Rename priority_twist → twist_instance.
--
-- Atlas generates this as DROP/CREATE for the table and its dependents,
-- which trips over view dependencies on source_channel.priority_twist_id.
-- To break those dependencies before the ALTER TABLE statements fire,
-- drop the views that reference the old column with CASCADE. They are
-- all rebuilt later in this migration with the new column names.
-- =====================================================================
DROP VIEW IF EXISTS "user"."priority_actor" CASCADE;
DROP VIEW IF EXISTS "user"."actor" CASCADE;
DROP VIEW IF EXISTS "public"."priority_child_twist" CASCADE;

-- Modify "sync_twist_for_note" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft threads are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN thread a ON a.id = n.thread_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        -- Only consider rows where meaningful fields actually changed, to avoid
        -- unnecessary twist_instance_sync updates from no-op upserts.
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE
            AND (n.content IS DISTINCT FROM o.content
                OR n.author_id IS DISTINCT FROM o.author_id
                OR n.source_created_at IS DISTINCT FROM o.source_created_at
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.re_note_id IS DISTINCT FROM o.re_note_id
                OR n.mentions IS DISTINCT FROM o.mentions
                OR n.actions IS DISTINCT FROM o.actions
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft threads
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: track sync state for twists that are mentioned in the note
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft threads are creates
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
                        INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                            VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (twist_instance_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN thread a ON a.id = n.thread_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id
                -- Only route to twists mentioned in this note
                AND pct.id = ANY (n.mentions)

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON pct.id = ANY (n.mentions)
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL
                AND n.created_by != pct.id

                    ORDER BY
                        id LOOP
                        INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                            VALUES (v_twist_instance_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (twist_instance_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: track sync state for twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN thread a ON a.id = n.thread_id
            JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for note creator
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create "twist_instance" table
CREATE TABLE "public"."twist_instance" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "priority_id" uuid NULL,
  "twist_id" bigint NOT NULL,
  "owner_id" uuid NOT NULL,
  "name" text NOT NULL,
  "config" jsonb NOT NULL DEFAULT '{}',
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "suspended_at" timestamptz NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "twist_instance_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "twist_instance_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "twist_instance_twist_id_fkey" FOREIGN KEY ("twist_id") REFERENCES "public"."twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_twist_instance_priority_id" to table: "twist_instance"
CREATE INDEX "idx_twist_instance_priority_id" ON "public"."twist_instance" ("priority_id");
-- Create index "idx_twist_instance_twist_id" to table: "twist_instance"
CREATE INDEX "idx_twist_instance_twist_id" ON "public"."twist_instance" ("twist_id");
-- Create "upsert_twist_instance" function
CREATE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row twist_instance;
BEGIN
    -- Source accounts have NULL priority_id; skip access check for those
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);

        -- Viewer enforcement: viewers cannot manage twists
        IF "user".get_effective_role(user_id, p_priority_id) = 'viewer' THEN
            RAISE EXCEPTION 'Viewer members cannot manage twists';
        END IF;
    END IF;
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    INSERT INTO twist_instance (id, priority_id, twist_id, owner_id, name, config, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_priority_id, p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            config = EXCLUDED.config,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_role text;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + priority
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_priority_id IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND priority_id = v_priority_id;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access and role in a single query
    SELECT
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_role
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.user_id = upsert_thread.user_id
        AND pu.archived_at IS NULL
        AND p.id = v_priority_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    IF v_role = 'viewer' THEN
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_id) THEN
            -- New thread: viewers cannot create public threads
            IF COALESCE(p_thread ->> 'access', p_defaults ->> 'access', 'members') = 'public' THEN
                RAISE EXCEPTION 'Viewer members can only create private threads';
            END IF;
        ELSE
            -- Existing thread: viewers can only modify their own non-public threads
            IF NOT EXISTS (
                SELECT 1 FROM thread
                WHERE id = v_id AND access != 'public' AND created_by = user_id
            ) THEN
                RAISE EXCEPTION 'Viewer members cannot modify threads they did not create';
            END IF;
        END IF;
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
            FROM "user".priority_expanded upe
            WHERE upe.priority_id = v_existing.priority_id
              AND upe.user_id = upsert_thread.user_id
              AND upe.archived_at IS NULL
        )),
        FALSE
    );
    -- Perform the upsert and return the full row.
    -- INSERT values fall through p_thread → p_defaults → v_existing so
    -- that on the UPDATE path the INSERT satisfies CHECK constraints even
    -- when the caller omits fields like title.
    INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, access, access_contacts, draft, key, icon)
        VALUES (
            v_id,
            v_created_by,
            v_priority_id,
            COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
            COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
            COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
            COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
            COALESCE(p_thread ->> 'access', p_defaults ->> 'access', v_existing.access, 'members'),
            CASE
                WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'access_contacts' AND jsonb_typeof(p_defaults -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem), ARRAY[]::uuid[])
                ELSE v_existing.access_contacts
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
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            access = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'access', p_defaults ->> 'access', thread.access)
            ELSE
                CASE WHEN p_thread ? 'access' THEN
                    p_thread ->> 'access'
                ELSE
                    thread.access
                END
            END,
            access_contacts = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_thread ? 'access_contacts' THEN
                    NULL
                WHEN p_defaults ? 'access_contacts' AND jsonb_typeof(p_defaults -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_defaults ? 'access_contacts' THEN
                    NULL
                ELSE thread.access_contacts END
            ELSE
                CASE WHEN p_thread ? 'access_contacts' AND jsonb_typeof(p_thread -> 'access_contacts') = 'array' THEN
                    COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'access_contacts') elem), ARRAY[]::uuid[])
                WHEN p_thread ? 'access_contacts' THEN
                    NULL
                ELSE
                    thread.access_contacts
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

    -- Peer thread_priority rows are populated by the file_thread_priority_peers
    -- trigger on thread, so both upsert_thread callers and raw inserts from
    -- the twist runtime share the same filing behaviour.

    RETURN v_result;
END;
$$;
-- Modify "upsert_note" function
CREATE OR REPLACE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_thread_id" uuid, "p_draft" boolean, "p_access_contacts" uuid[], "p_content" text, "p_actions" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text, "p_merged_from_thread_id" uuid DEFAULT NULL::uuid) RETURNS "public"."note" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_thread_author_id uuid;
    v_thread_access text;
    v_thread_created_by uuid;
    v_thread_access_contacts uuid[];
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        thread
    WHERE
        id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    -- Check thread access
    SELECT access, created_by, access_contacts
    INTO v_thread_access, v_thread_created_by, v_thread_access_contacts
    FROM thread WHERE id = p_thread_id;

    IF v_thread_access != 'public' THEN
        IF v_thread_created_by != upsert_note.user_id
           AND NOT (v_thread_access = 'members' AND "user".get_effective_role(user_id, v_priority_id) = 'member')
           AND NOT (COALESCE(v_thread_access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(upsert_note.user_id))
        THEN
            RAISE EXCEPTION 'Access denied to private thread';
        END IF;
    END IF;

    -- Viewer enforcement: in public threads, force note to be author-only
    IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        IF v_thread_access = 'public' THEN
            p_access_contacts := ARRAY[]::uuid[];
        END IF;
        -- In non-public threads: keep whatever access_contacts was passed (default NULL = all thread viewers)
    END IF;

    v_created_by := COALESCE(p_created_by, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE(p_author_id, v_created_by);
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
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (uuidv7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (thread_id, key)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, thread_id, draft, access_contacts, content, actions, mentions, re_note_id, source_created_at, key, merged_from_thread_id)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_thread_id, COALESCE(p_draft, FALSE), p_access_contacts, p_content, p_actions, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key, p_merged_from_thread_id)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = note.author_id,
                created_by = note.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                thread_id = EXCLUDED.thread_id,
                draft = EXCLUDED.draft,
                access_contacts = EXCLUDED.access_contacts,
                content = EXCLUDED.content,
                actions = EXCLUDED.actions,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = COALESCE(EXCLUDED.key, note.key),
                merged_from_thread_id = EXCLUDED.merged_from_thread_id,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Drop "priority_twist_thread_schedule" view
DROP VIEW IF EXISTS "public"."priority_twist_thread_schedule";
-- Drop "priority_twist_thread_read" view
DROP VIEW IF EXISTS "public"."priority_twist_thread_read";
-- Drop "priority_twist_schedule_contact" view
DROP VIEW IF EXISTS "public"."priority_twist_schedule_contact";
-- Drop "priority_twist_channel_link_create" view
DROP VIEW IF EXISTS "public"."priority_twist_channel_link_create";
-- Drop "priority_twist_channel_link_update" view
DROP VIEW IF EXISTS "public"."priority_twist_channel_link_update";
-- Drop "priority_twist_channel_note_create" view
DROP VIEW IF EXISTS "public"."priority_twist_channel_note_create";
-- Drop "priority_twist_link_update" view
DROP VIEW IF EXISTS "public"."priority_twist_link_update";
-- Drop "priority_twist_note_create" view
DROP VIEW IF EXISTS "public"."priority_twist_note_create";
-- Drop "priority_twist_note_update" view
DROP VIEW IF EXISTS "public"."priority_twist_note_update";
-- Drop "priority_twist_thread_tag_change" view
DROP VIEW IF EXISTS "public"."priority_twist_thread_tag_change";
-- Drop "priority_twist_thread_update" view
DROP VIEW IF EXISTS "public"."priority_twist_thread_update";
-- Set comment to column: "created_by" on table: "thread"
COMMENT ON COLUMN "public"."thread"."created_by" IS 'The user_id or twist_instance_id that actually created this thread. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';
-- Modify "upsert_link" function
CREATE OR REPLACE FUNCTION "user"."upsert_link" ("user_id" uuid, "p_link" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."link" LANGUAGE plpgsql AS $$
DECLARE
    v_result link;
    v_id uuid;
    v_thread_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_created_by uuid;
    v_twist_id bigint;
    v_author_id uuid;
    v_assignee_id uuid;
    v_priority_id uuid;
    v_role text;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_link ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_link ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_source := p_link ->> 'source';
    v_created_by := COALESCE((p_link ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    v_author_id := COALESCE((p_link ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);

    -- DERIVE source_priority_root if explicitly provided
    IF p_link ? 'source_priority_root' AND (p_link ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_link ->> 'source_priority_root')::ltree;
    END IF;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Resolve thread_id from existing link if missing
    IF v_thread_id IS NULL THEN
        SELECT
            l.thread_id INTO v_thread_id
        FROM
            link l
        WHERE
            l.id = v_id;
    END IF;

    IF v_thread_id IS NULL THEN
        RAISE EXCEPTION 'thread_id must be provided';
    END IF;

    -- Single query: get priority_id, derive source_priority_root, check access + role
    SELECT
        t.priority_id,
        CASE WHEN v_source_priority_root IS NULL AND v_source IS NOT NULL
            THEN subpath(p.path, 0, 1)
            ELSE v_source_priority_root
        END,
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_priority_id, v_source_priority_root, v_role
    FROM
        thread t
        JOIN priority p ON p.id = t.priority_id
        LEFT JOIN priority pp ON p.path <@ pp.path
        LEFT JOIN priority_user pu ON pu.priority_id = pp.id
            AND pu.user_id = upsert_link.user_id
            AND pu.archived_at IS NULL
    WHERE
        t.id = v_thread_id
    GROUP BY t.priority_id, p.path;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    IF v_role = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot create or modify links';
    END IF;

    -- For existing links, preserve the original created_by (any priority member
    -- can update link fields like assignee_id without owning the creator entity).
    -- For new links, validate that created_by is the user or their owned twist.
    -- Single query instead of EXISTS + separate SELECT
    DECLARE
        v_existing_created_by uuid;
    BEGIN
        SELECT l.created_by INTO v_existing_created_by FROM link l WHERE l.id = v_id;
        IF v_existing_created_by IS NOT NULL THEN
            v_created_by := v_existing_created_by;
        ELSE
            IF v_created_by IS DISTINCT FROM user_id THEN
                IF NOT EXISTS (
                    SELECT
                        1
                    FROM
                        twist_instance pt
                    WHERE
                        pt.id = v_created_by
                        AND pt.owner_id = upsert_link.user_id) THEN
                    RAISE EXCEPTION 'created_by must be user or owned twist_instance';
                END IF;
            END IF;
        END IF;
    END;

    -- DERIVE twist_id from created_by (twist_instance_id)
    IF p_link ? 'twist_id' AND (p_link ->> 'twist_id') IS NOT NULL THEN
        v_twist_id := (p_link ->> 'twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_twist_id
        FROM
            twist_instance pt
        WHERE
            pt.id = v_created_by;
    END IF;

    -- Resolve assignee
    IF p_link ? 'assignee_id' THEN
        v_assignee_id := (p_link ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSE
        v_assignee_id := NULL;
    END IF;

    -- Perform the upsert and return the full row
    INSERT INTO link (id, thread_id, source, source_created_at, author_id, twist_id,
        created_by, updated_by, sync_depth, title, preview, assignee_id, type, status,
        actions, meta, source_url, embedding, match, merged_from_thread_id, related_source,
        channel_id)
        VALUES (v_id, v_thread_id, v_source,
            COALESCE((p_link ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()),
            v_author_id, v_twist_id, v_created_by,
            COALESCE((p_link ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0),
            COALESCE((p_link ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint),
            COALESCE(p_link ->> 'title', p_defaults ->> 'title'),
            COALESCE(p_link ->> 'preview', p_defaults ->> 'preview'),
            v_assignee_id,
            COALESCE(p_link ->> 'type', p_defaults ->> 'type'),
            COALESCE(p_link ->> 'status', p_defaults ->> 'status'),
            COALESCE(p_link -> 'actions', p_defaults -> 'actions'),
            COALESCE(p_link -> 'meta', p_defaults -> 'meta'),
            COALESCE(p_link ->> 'source_url', p_defaults ->> 'source_url'),
            COALESCE((p_link ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec),
            COALESCE(p_link -> 'match', p_defaults -> 'match'),
            COALESCE((p_link ->> 'merged_from_thread_id')::uuid, (p_defaults ->> 'merged_from_thread_id')::uuid),
            COALESCE(p_link ->> 'related_source', p_defaults ->> 'related_source'),
            COALESCE(p_link ->> 'channel_id', p_defaults ->> 'channel_id'))
    ON CONFLICT (source, source_priority_root)
        DO UPDATE SET
            title = CASE WHEN p_link ? 'title' THEN
                p_link ->> 'title'
            ELSE
                link.title
            END,
            preview = CASE WHEN p_link ? 'preview' THEN
                p_link ->> 'preview'
            ELSE
                link.preview
            END,
            assignee_id = CASE WHEN p_link ? 'assignee_id' THEN
                (p_link ->> 'assignee_id')::uuid
            ELSE
                COALESCE(v_assignee_id, link.assignee_id)
            END,
            type = CASE WHEN p_link ? 'type' THEN
                p_link ->> 'type'
            ELSE
                link.type
            END,
            status = CASE WHEN p_link ? 'status' THEN
                p_link ->> 'status'
            ELSE
                link.status
            END,
            actions = CASE WHEN p_link ? 'actions' THEN
                p_link -> 'actions'
            ELSE
                link.actions
            END,
            meta = CASE WHEN p_link ? 'meta' THEN
                p_link -> 'meta'
            ELSE
                link.meta
            END,
            source_url = CASE WHEN p_link ? 'source_url' THEN
                p_link ->> 'source_url'
            ELSE
                link.source_url
            END,
            updated_by = CASE WHEN p_link ? 'updated_by' THEN
                (p_link ->> 'updated_by')::integer
            ELSE
                link.updated_by
            END,
            sync_depth = CASE WHEN p_link ? 'sync_depth' THEN
                (p_link ->> 'sync_depth')::smallint
            ELSE
                link.sync_depth
            END,
            source = COALESCE(v_source, link.source),
            source_priority_root = COALESCE(v_source_priority_root, link.source_priority_root),
            created_by = v_created_by,
            twist_id = v_twist_id,
            -- Keep existing thread_id on update to prevent race conditions
            -- where concurrent saveLink calls create orphaned threads
            thread_id = link.thread_id,
            merged_from_thread_id = CASE WHEN p_link ? 'merged_from_thread_id' THEN
                (p_link ->> 'merged_from_thread_id')::uuid
            ELSE
                link.merged_from_thread_id
            END,
            related_source = CASE WHEN p_link ? 'related_source' THEN
                p_link ->> 'related_source'
            ELSE
                link.related_source
            END,
            channel_id = CASE WHEN p_link ? 'channel_id' THEN
                p_link ->> 'channel_id'
            ELSE
                link.channel_id
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Create "sync_user_for_twist_instance" function
CREATE FUNCTION "public"."sync_user_for_twist_instance" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL

    UNION

    -- Source accounts (NULL priority_id): notify the owner directly
    SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    WHERE
        n.priority_id IS NULL

    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_twist_instance_insert"
CREATE TRIGGER "user_sync_twist_instance_insert" AFTER INSERT ON "public"."twist_instance" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_twist_instance"();
-- Create trigger "set_twist_instance_created_at"
CREATE TRIGGER "set_twist_instance_created_at" BEFORE INSERT ON "public"."twist_instance" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "set_twist_instance_owner_id" function
CREATE FUNCTION "public"."set_twist_instance_owner_id" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.owner_id IS NULL THEN
        RAISE EXCEPTION 'owner_id must be provided';
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_twist_instance_owner_id"
CREATE TRIGGER "set_twist_instance_owner_id" BEFORE INSERT ON "public"."twist_instance" FOR EACH ROW EXECUTE FUNCTION "public"."set_twist_instance_owner_id"();
-- Create trigger "archive_twist_tags_on_archive"
CREATE TRIGGER "archive_twist_tags_on_archive" AFTER UPDATE OF "archived_at" ON "public"."twist_instance" FOR EACH ROW WHEN ((old.archived_at IS NULL) AND (new.archived_at IS NOT NULL)) EXECUTE FUNCTION "public"."archive_twist_tags"();
-- Create trigger "user_sync_twist_instance_update"
CREATE TRIGGER "user_sync_twist_instance_update" AFTER UPDATE ON "public"."twist_instance" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_twist_instance"();
-- Create "prevent_twist_instance_immutable_changes" function
CREATE FUNCTION "public"."prevent_twist_instance_immutable_changes" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Prevent changing twist_id
    IF OLD.twist_id IS DISTINCT FROM NEW.twist_id THEN
        RAISE EXCEPTION 'Cannot change twist_id of an existing twist_instance';
    END IF;
    -- Prevent changing owner_id
    IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION 'Cannot change owner_id of an existing twist_instance';
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "prevent_twist_instance_immutable_changes"
CREATE TRIGGER "prevent_twist_instance_immutable_changes" BEFORE UPDATE ON "public"."twist_instance" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_twist_instance_immutable_changes"();
-- Create "sync_user_for_twist_instance_connection" function
CREATE FUNCTION "public"."sync_user_for_twist_instance_connection" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_connected_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(connected_at) INTO v_max_connected_at
    FROM
        new_table;
    -- Notify each affected user directly
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_connected_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "twist_instance_connection" table
CREATE TABLE "public"."twist_instance_connection" (
  "twist_instance_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "provider" text NOT NULL,
  "actor_id" uuid NOT NULL,
  "connected_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("twist_instance_id", "user_id", "provider"),
  CONSTRAINT "twist_instance_connection_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "twist_instance_connection_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_twist_instance_connection_instance" to table: "twist_instance_connection"
CREATE INDEX "idx_twist_instance_connection_instance" ON "public"."twist_instance_connection" ("twist_instance_id");
-- Create index "idx_twist_instance_connection_user_id" to table: "twist_instance_connection"
CREATE INDEX "idx_twist_instance_connection_user_id" ON "public"."twist_instance_connection" ("user_id");
-- Create trigger "user_sync_twist_instance_connection_delete"
CREATE TRIGGER "user_sync_twist_instance_connection_delete" AFTER DELETE ON "public"."twist_instance_connection" REFERENCING OLD TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_twist_instance_connection"();
-- Create trigger "user_sync_twist_instance_connection_insert"
CREATE TRIGGER "user_sync_twist_instance_connection_insert" AFTER INSERT ON "public"."twist_instance_connection" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_twist_instance_connection"();
-- Create trigger "set_twist_instance_updated_at"
CREATE TRIGGER "set_twist_instance_updated_at" BEFORE INSERT OR UPDATE ON "public"."twist_instance" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Set comment to column: "author_id" on table: "note"
COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by users, this is the user''s contact ID (never the user_id). For notes created by twists, this is the twist''s twist_instance_id.';
-- Set comment to column: "created_by" on table: "note"
COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or twist_instance_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';
-- Set comment to column: "mentions" on table: "note"
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of twist_instance_ids (twists and connectors) mentioned in this note. Used for dispatch routing only — user visibility is handled by access_contacts.';
-- Modify "ensure_link_assignee_priority_contact" function
CREATE OR REPLACE FUNCTION "public"."ensure_link_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the priority_id from the thread or direct link priority
    IF NEW.thread_id IS NOT NULL THEN
        SELECT
            t.priority_id INTO v_priority_id
        FROM
            thread t
        WHERE
            t.id = NEW.thread_id;
    ELSE
        v_priority_id := NEW.priority_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a twist_instance)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
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

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.match_priority_for_user(r.peer_user_id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id, TRUE)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;
-- Modify "populate_thread_priority_for_author" function
CREATE OR REPLACE FUNCTION "public"."populate_thread_priority_for_author" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF NEW.priority_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Author is a real user
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_user_id := NEW.created_by;
    ELSE
        -- Author is a twist_instance instance; file for its owner
        SELECT pt.owner_id INTO v_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    IF v_user_id IS NOT NULL THEN
        INSERT INTO thread_priority (thread_id, user_id, priority_id, matched)
        VALUES (NEW.id, v_user_id, NEW.priority_id, FALSE)
        ON CONFLICT (thread_id, user_id)
        DO UPDATE SET priority_id = EXCLUDED.priority_id, updated_at = now();
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "recompute_outstanding_tasks" function
CREATE OR REPLACE FUNCTION "public"."recompute_outstanding_tasks" ("p_thread_id" uuid, "p_user_id" uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_has_outstanding boolean;
BEGIN
    -- Check 1: Notes with active todo tag for any of the user's contacts
    SELECT EXISTS(
        SELECT 1
        FROM note_tag nt
        JOIN note n ON n.id = nt.note_id
        JOIN contact c ON c.id = nt.actor_id
        WHERE n.thread_id = p_thread_id
          AND c.user_id = p_user_id
          AND nt.tag_id = 1  -- Tag.todo
          AND nt.archived_at IS NULL
          AND n.archived_at IS NULL
    ) INTO v_has_outstanding;

    -- Check 2: Links assigned to user (or unassigned) with non-done status.
    -- Check channel-level linkTypes first (dynamic, UUID-based statuses from getChannels),
    -- falling back to twist-level permissions (static string-based statuses).
    IF NOT v_has_outstanding THEN
        SELECT EXISTS(
            SELECT 1
            FROM link l
            JOIN contact c ON c.user_id = p_user_id
            LEFT JOIN source_channel sc ON sc.twist_instance_id = l.created_by
              AND sc.channel_id = l.channel_id
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE WHEN sc.link_types IS NOT NULL THEN sc.link_types
                ELSE (
                    SELECT jsonb_agg(lt_item)
                    FROM twist_instance pt2
                    JOIN twist tw ON tw.id = pt2.twist_id
                    CROSS JOIN LATERAL jsonb_array_elements(tw.permissions -> '_providers') AS provider
                    CROSS JOIN LATERAL jsonb_array_elements(provider -> 'linkTypes') AS lt_item
                    WHERE pt2.id = l.created_by
                )
                END
            ) AS lt
            CROSS JOIN LATERAL jsonb_array_elements(lt -> 'statuses') AS status_def
            WHERE l.thread_id = p_thread_id
              AND l.status IS NOT NULL
              AND (l.assignee_id IS NULL OR l.assignee_id = c.id)
              AND lt ->> 'type' = l.type
              AND status_def ->> 'status' = l.status
              AND COALESCE((status_def ->> 'done')::boolean, false) = false
        ) INTO v_has_outstanding;
    END IF;

    -- Update the per-user schedule
    UPDATE schedule
    SET outstanding_tasks = v_has_outstanding
    WHERE thread_id = p_thread_id
      AND user_id = p_user_id
      AND occurrence IS NULL;
END;
$$;
-- Modify "sync_thread_contacts" function
CREATE OR REPLACE FUNCTION "public"."sync_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    _author_user_id uuid;
    _author_contact_id uuid;
    _contacts uuid[];
BEGIN
    -- Start from access_contacts (legacy source of truth) and fall back
    -- to an empty array. Cast to uuid[] to normalise NULL.
    _contacts := COALESCE(NEW.access_contacts, ARRAY[]::uuid[]);

    -- Resolve created_by to a user: either it's a user already or it's
    -- a twist_instance instance whose owner_id is the user.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        _author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO _author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    IF _author_user_id IS NOT NULL THEN
        _author_contact_id := "user".user_contact_id(_author_user_id);
        IF _author_contact_id IS NOT NULL
           AND NOT (_author_contact_id = ANY(_contacts)) THEN
            _contacts := _contacts || _author_contact_id;
        END IF;
    END IF;

    NEW.contacts := _contacts;
    RETURN NEW;
END;
$$;
-- Modify "sync_twist_for_link" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table;
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n;
    END IF;
    -- Exit early if nothing to sync
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts)
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN twist_instance pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'link', 'create', v_create_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    -- Process UPDATE operations
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN twist_instance pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN twist_instance pct ON n.created_by = pct.id
        WHERE
            pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'link', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Set comment to column: "created_by" on table: "link"
COMMENT ON COLUMN "public"."link"."created_by" IS 'The user_id or twist_instance_id that actually created this link. Used for filtering callbacks and permissions.';
-- Modify "sync_twist_for_note_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft threads.
    -- For UPDATE, only consider rows where tag state actually changed to avoid
    -- unnecessary twist_instance_sync updates from no-op upserts.
    IF TG_OP = 'UPDATE' THEN
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE
            AND (n.archived_at IS DISTINCT FROM o.archived_at
                OR n.tag_id IS DISTINCT FROM o.tag_id
                OR n.actor_id IS DISTINCT FROM o.actor_id);
    ELSE
        SELECT
            MAX(n.updated_at) INTO v_max_updated_at
        FROM
            new_table n
            JOIN note nt ON nt.id = n.note_id
            JOIN thread a ON a.id = nt.thread_id
        WHERE
            nt.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to tags on draft notes or draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected notes
    -- Only consider tags on non-draft notes on non-draft threads
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread a ON a.id = nt.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this note
        AND nt.created_by = pct.id

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN twist_instance pct ON nt.created_by = pct.id
    WHERE
        nt.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                VALUES (v_twist_instance_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft rows are creates
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        -- Only consider rows where meaningful fields actually changed, to avoid
        -- unnecessary twist_instance_sync updates from no-op upserts (which cause
        -- SyncRecovery to re-trigger connectors in a feedback loop).
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND (n.title IS DISTINCT FROM o.title
                OR n.preview IS DISTINCT FROM o.preview
                OR n.archived_at IS DISTINCT FROM o.archived_at
                OR n.draft IS DISTINCT FROM o.draft
                OR n.access IS DISTINCT FROM o.access
                OR n.access_contacts IS DISTINCT FROM o.access_contacts
                OR n.icon IS DISTINCT FROM o.icon
                OR n.priority_id IS DISTINCT FROM o.priority_id
                OR n.updated_by IS DISTINCT FROM o.updated_by);
    END IF;
    -- Exit early if all changes were to draft threads (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft rows are creates
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN twist_instance pct ON n.created_by = pct.id
            WHERE
                n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_twist_instance_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this thread
                AND n.created_by = pct.id

            UNION

            -- Direct match for account-based sources (NULL priority_id)
            SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN twist_instance pct ON n.created_by = pct.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.priority_id IS NULL
                AND pct.archived_at IS NULL

            ORDER BY
                id LOOP
                    INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                        VALUES (v_twist_instance_id, 'thread', 'create', v_create_timestamp)
                    ON CONFLICT (twist_instance_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published threads)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_twist_instance_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for the twist that created this thread
            AND n.created_by = pct.id

        UNION

        -- Direct match for account-based sources (NULL priority_id)
        SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN twist_instance pct ON n.created_by = pct.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.priority_id IS NULL
            AND pct.archived_at IS NULL

        ORDER BY
            id LOOP
                INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                    VALUES (v_twist_instance_id, 'thread', 'update', v_update_timestamp)
                ON CONFLICT (twist_instance_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Modify "sync_twist_for_thread_tag" function
CREATE OR REPLACE FUNCTION "public"."sync_twist_for_thread_tag" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_twist_instance_id uuid;
BEGIN
    -- Only consider tags on non-draft threads
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft threads
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected threads
    -- Only consider tags on non-draft threads
    FOR v_twist_instance_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN twist_instance pct ON pct.priority_id = p_parent.id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this thread
        AND a.created_by = pct.id

    UNION

    -- Direct match for account-based sources (NULL priority_id)
    SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN twist_instance pct ON a.created_by = pct.id
    WHERE
        a.draft = FALSE
        AND pct.priority_id IS NULL
        AND pct.archived_at IS NULL

    ORDER BY
        id LOOP
            INSERT INTO twist_instance_sync (twist_instance_id, entity, operation, last_update_at)
                VALUES (v_twist_instance_id, 'thread', 'update', v_max_updated_at)
            ON CONFLICT (twist_instance_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (twist_instance_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_source_channel" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_source_channel" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Notify the owner of the source account
    FOR v_user_id IN SELECT DISTINCT
        pt.owner_id
    FROM
        new_table n
        JOIN twist_instance pt ON pt.id = n.twist_instance_id
    ORDER BY
        pt.owner_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'source_channel', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "twist_instance_sync" table
CREATE TABLE "public"."twist_instance_sync" (
  "twist_instance_id" uuid NOT NULL,
  "entity" text NOT NULL,
  "operation" "public"."sync_operation" NOT NULL,
  "last_update_at" timestamptz NOT NULL,
  "last_sync_at" timestamptz NOT NULL DEFAULT '1970-01-01 00:00:00+00',
  PRIMARY KEY ("twist_instance_id", "entity", "operation"),
  CONSTRAINT "twist_instance_sync_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_twist_instance_sync_pending" to table: "twist_instance_sync"
CREATE INDEX "idx_twist_instance_sync_pending" ON "public"."twist_instance_sync" ("twist_instance_id") WHERE (last_update_at > last_sync_at);
-- Drop "get_stale_twist_syncs" function
DROP FUNCTION "public"."get_stale_twist_syncs";
-- Create "get_stale_twist_syncs" function
CREATE FUNCTION "public"."get_stale_twist_syncs" ("p_stale_threshold" timestamptz, "p_limit" integer DEFAULT 50) RETURNS TABLE ("twist_instance_id" uuid) LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT DISTINCT
        pts.twist_instance_id
    FROM
        twist_instance_sync pts
        JOIN twist_instance pt ON pt.id = pts.twist_instance_id
    WHERE
        pts.last_update_at > pts.last_sync_at -- Has pending updates
        AND pts.last_sync_at < p_stale_threshold -- Hasn't synced recently
        AND pt.archived_at IS NULL -- Skip archived twists
    ORDER BY
        pts.twist_instance_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$$;
-- Create "get_twist_instance_owner_contact" function
CREATE FUNCTION "public"."get_twist_instance_owner_contact" ("p_twist_instance_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT
        public.get_primary_contact_id(pt.owner_id)
    FROM
        twist_instance pt
    WHERE
        pt.id = p_twist_instance_id;
$$;
-- Drop index "idx_secure_option_per_user" from table: "secure_option"
DROP INDEX "public"."idx_secure_option_per_user";
-- Drop index "idx_secure_option_pt" from table: "secure_option"
DROP INDEX "public"."idx_secure_option_pt";
-- Drop index "idx_secure_option_shared" from table: "secure_option"
DROP INDEX "public"."idx_secure_option_shared";
-- Modify "secure_option" table
ALTER TABLE "public"."secure_option" RENAME COLUMN "priority_twist_id" TO "twist_instance_id";
ALTER TABLE "public"."secure_option" DROP CONSTRAINT IF EXISTS "secure_option_priority_twist_id_fkey";
ALTER TABLE "public"."secure_option" ADD CONSTRAINT "secure_option_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Create index "idx_secure_option_per_user" to table: "secure_option"
CREATE UNIQUE INDEX "idx_secure_option_per_user" ON "public"."secure_option" ("twist_instance_id", "key", "user_id") WHERE (user_id IS NOT NULL);
-- Create index "idx_secure_option_pt" to table: "secure_option"
CREATE INDEX "idx_secure_option_pt" ON "public"."secure_option" ("twist_instance_id");
-- Create index "idx_secure_option_shared" to table: "secure_option"
CREATE UNIQUE INDEX "idx_secure_option_shared" ON "public"."secure_option" ("twist_instance_id", "key") WHERE (user_id IS NULL);
-- Modify "source_channel" table: rename column instead of drop/add so
-- any remaining view/function dependencies follow the rename automatically.
ALTER TABLE "public"."source_channel" RENAME COLUMN "priority_twist_id" TO "twist_instance_id";
ALTER TABLE "public"."source_channel" DROP CONSTRAINT IF EXISTS "source_channel_priority_twist_id_channel_id_key";
ALTER TABLE "public"."source_channel" DROP CONSTRAINT IF EXISTS "source_channel_priority_twist_id_fkey";
ALTER TABLE "public"."source_channel" ADD CONSTRAINT "source_channel_twist_instance_id_channel_id_key" UNIQUE ("twist_instance_id", "channel_id");
ALTER TABLE "public"."source_channel" ADD CONSTRAINT "source_channel_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
DROP INDEX IF EXISTS "public"."idx_source_channel_priority_twist_id";
-- Create index "idx_source_channel_twist_instance_id" to table: "source_channel"
CREATE INDEX "idx_source_channel_twist_instance_id" ON "public"."source_channel" ("twist_instance_id");
-- Modify "usage" table
ALTER TABLE "public"."usage" RENAME COLUMN "priority_twist_id" TO "twist_instance_id";
ALTER TABLE "public"."usage" DROP CONSTRAINT IF EXISTS "usage_priority_twist_id_hour_cost_id_key";
ALTER TABLE "public"."usage" DROP CONSTRAINT IF EXISTS "usage_priority_twist_id_fkey";
ALTER TABLE "public"."usage" ADD CONSTRAINT "usage_twist_instance_id_hour_cost_id_key" UNIQUE ("twist_instance_id", "hour", "cost_id");
ALTER TABLE "public"."usage" ADD CONSTRAINT "usage_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
DROP INDEX IF EXISTS "public"."idx_usage_priority_twist_id";
-- Create index "idx_usage_twist_instance_id" to table: "usage"
CREATE INDEX "idx_usage_twist_instance_id" ON "public"."usage" ("twist_instance_id");
-- Create "twist_instance_channel" table
CREATE TABLE "public"."twist_instance_channel" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "twist_instance_id" uuid NOT NULL,
  "source_twist_instance_id" uuid NOT NULL,
  "channel_id" text NOT NULL,
  "enabled" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "twist_instance_channel_twist_instance_id_source_twist_insta_key" UNIQUE ("twist_instance_id", "source_twist_instance_id", "channel_id"),
  CONSTRAINT "twist_instance_channel_source_twist_instance_id_fkey" FOREIGN KEY ("source_twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "twist_instance_channel_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_twist_instance_channel_instance" to table: "twist_instance_channel"
CREATE INDEX "idx_twist_instance_channel_instance" ON "public"."twist_instance_channel" ("twist_instance_id");
-- Create index "idx_twist_instance_channel_source" to table: "twist_instance_channel"
CREATE INDEX "idx_twist_instance_channel_source" ON "public"."twist_instance_channel" ("source_twist_instance_id", "channel_id");
-- Create "twist_instance_thread_schedule" view
CREATE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.id = a.created_by AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.archived_at IS NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
-- Create "twist_instance_thread_read" view
CREATE VIEW "public"."twist_instance_thread_read" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.id = a.created_by AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Create "twist_instance_schedule_contact" view
CREATE VIEW "public"."twist_instance_schedule_contact" (
  "twist_instance_id",
  "schedule_contact_id",
  "schedule_id",
  "contact_id",
  "status",
  "role",
  "archived_at",
  "thread_id",
  "link_id",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    s.thread_id,
    s.link_id,
    sc.updated_at,
    a.priority_id
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.link l ON l.thread_id = a.id AND l.created_by = pt.id
     JOIN public.schedule s ON s.link_id = l.id
     JOIN public.schedule_contact sc ON sc.schedule_id = s.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
-- Rename a view column from "priority_twist_id" to "twist_instance_id"
ALTER VIEW "user"."source_channel" RENAME COLUMN "priority_twist_id" TO "twist_instance_id";
-- Modify "source_channel" view
CREATE OR REPLACE VIEW "user"."source_channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "priority_id",
  "enabled",
  "create_threads",
  "link_types",
  "create_threads_by_type",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.priority_id,
    sc.enabled,
    sc.create_threads,
    sc.link_types,
    sc.create_threads_by_type,
    sc.created_at,
    sc.updated_at
   FROM public.source_channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id;
-- Modify "actor" view
CREATE OR REPLACE VIEW "public"."actor" (
  "id",
  "created_at",
  "updated_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "archived_at"
) AS SELECT c.id,
    c.created_at,
    c.updated_at,
        CASE
            WHEN c.user_id IS NOT NULL THEN 'user'::text
            ELSE 'contact'::text
        END AS type,
    c.name,
    c.email,
    c.avatar_url,
    c.archived_at
   FROM public.contact c
UNION ALL
 SELECT pt.id,
    pt.created_at,
    pt.updated_at,
    'twist_instance'::text AS type,
    pt.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at
   FROM public.twist_instance pt;
-- Modify "priority_actor" view
CREATE OR REPLACE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "depth",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    depth,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT ancestor_contacts.user_id,
            ancestor_contacts.priority_path,
            ancestor_contacts.actor_id,
            ancestor_contacts.depth,
            ancestor_contacts.created_at,
            ancestor_contacts.updated_at,
            ancestor_contacts.archived_at
           FROM ( SELECT DISTINCT ON (upe.user_id, upe.path, pc.contact_id) upe.user_id,
                    upe.path AS priority_path,
                    pc.contact_id AS actor_id,
                    public.nlevel(p.path) - public.nlevel(ancestor.path) AS depth,
                    LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
                    GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                        CASE
                            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                            ELSE c.archived_at
                        END AS archived_at
                   FROM "user".priority_expanded upe
                     JOIN public.priority p ON p.id = upe.priority_id
                     JOIN public.priority ancestor ON p.path OPERATOR(public.<@) ancestor.path AND ancestor.user_id = p.user_id
                     JOIN public.priority_contact pc ON pc.priority_id = ancestor.id
                     JOIN public.contact c ON c.id = pc.contact_id
                  WHERE c.user_id IS NULL OR c."primary" = true
                  ORDER BY upe.user_id, upe.path, pc.contact_id, (public.nlevel(ancestor.path)) DESC) ancestor_contacts
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.twist_instance pt ON pt.priority_id = upe.priority_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            GREATEST(pt.updated_at, sc.updated_at) AS updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.source_channel sc ON sc.priority_id = upe.priority_id
             JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id AND pt.priority_id IS NULL) actors;
-- Modify "priority_child_twist" view
CREATE OR REPLACE VIEW "public"."priority_child_twist" (
  "id",
  "priority_id",
  "twist_id",
  "owner_id",
  "name",
  "config",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url",
  "priority_child_id"
) AS SELECT pt.id,
    pt.priority_id,
    pt.twist_id,
    pt.owner_id,
    pt.name,
    pt.config,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    child_p.id AS priority_child_id
   FROM public.twist_instance pt
     JOIN public.priority install_p ON pt.priority_id = install_p.id
     JOIN public.priority child_p ON child_p.path OPERATOR(public.<@) install_p.path
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Modify "twist" view
CREATE OR REPLACE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "priority_id",
  "twist_id",
  "twist_environment",
  "is_source",
  "shared",
  "key_option",
  "owner_id",
  "name",
  "config",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = upe.user_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = upe.user_id))
        END AS user_connected
   FROM public.twist_instance pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
UNION ALL
 SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.config,
    t.logo_url,
    t.logo_url_dark,
    ( SELECT jsonb_agg(lt.value) AS jsonb_agg
           FROM jsonb_array_elements(t.permissions -> '_providers'::text) p(value),
            LATERAL jsonb_array_elements(p.value -> 'linkTypes'::text) lt(value)) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created'::text)::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned'::text)::boolean, false) AS default_mention_mentioned,
        CASE
            WHEN t.shared THEN (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id))
            ELSE (EXISTS ( SELECT 1
               FROM public.twist_instance_connection ptc
              WHERE ptc.twist_instance_id = pt.id AND ptc.user_id = pt.owner_id))
        END AS user_connected
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
  WHERE t.is_source = true AND pt.priority_id IS NULL;
-- Create "twist_instance_channel_link_create" view
CREATE VIEW "public"."twist_instance_channel_link_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Create "twist_instance_channel_link_update" view
CREATE VIEW "public"."twist_instance_channel_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.twist_instance_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "twist_instance_channel_note_create" view
CREATE VIEW "public"."twist_instance_channel_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
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
  "tags"
) AS SELECT DISTINCT ON (ptc.twist_instance_id, n.id) ptc.twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
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
    t.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_twist_instance_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.twist_instance pt ON pt.id = ptc.twist_instance_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.twist_instance_id AND n.created_at > pt.created_at
  ORDER BY ptc.twist_instance_id, n.id, n.created_at;
-- Create "twist_instance_link_update" view
CREATE VIEW "public"."twist_instance_link_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT l.created_by AS twist_instance_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread t ON t.priority_id = pc.id
     JOIN public.link l ON l.thread_id = t.id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE t.draft = false AND pt.id = l.created_by AND l.updated_at > l.created_at AND public.updated_by_uuid(pt.id) <> l.updated_by::numeric AND pt.archived_at IS NULL AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "twist_instance_note_create" view
CREATE VIEW "public"."twist_instance_note_create" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
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
  "tags"
) AS SELECT pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id AND a.archived_at IS NULL
     JOIN public.note n ON n.thread_id = a.id AND (pt.id = ANY (n.mentions))
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
UNION ALL
 SELECT pt.id AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON pt.id = ANY (n.mentions)
     JOIN public.thread a ON a.id = n.thread_id AND a.archived_at IS NULL
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE pt.priority_id IS NULL AND n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
  ORDER BY 3;
-- Create "twist_instance_note_update" view
CREATE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
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
  "tags"
) AS SELECT n.created_by AS twist_instance_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
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
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.note n ON a.id = n.thread_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Create "twist_instance_thread_tag_change" view
CREATE VIEW "public"."twist_instance_thread_tag_change" (
  "twist_instance_id",
  "thread_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.thread_tag at
     JOIN public.thread a ON a.id = at.thread_id
     JOIN public.priority_child_twist pct ON pct.priority_child_id = a.priority_id AND pct.id = a.created_by
  WHERE a.draft = false;
-- Create "twist_instance_thread_update" view
CREATE VIEW "public"."twist_instance_thread_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.twist_instance pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id = a.created_by AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Drop "priority_twist_channel" table
DROP TABLE "public"."priority_twist_channel";
-- Drop "upsert_priority_twist" function
DROP FUNCTION "user"."upsert_priority_twist";
-- Drop "get_priority_twist_owner_contact" function
DROP FUNCTION "public"."get_priority_twist_owner_contact";
-- Drop "priority_twist_connection" table
DROP TABLE "public"."priority_twist_connection";
-- Drop "priority_twist_sync" table
DROP TABLE "public"."priority_twist_sync";
-- Drop "priority_twist" table
DROP TABLE "public"."priority_twist";
-- Drop "prevent_priority_twist_immutable_changes" function
DROP FUNCTION "public"."prevent_priority_twist_immutable_changes";
-- Drop "set_priority_twist_owner_id" function
DROP FUNCTION "public"."set_priority_twist_owner_id";
-- Drop "sync_user_for_priority_twist" function
DROP FUNCTION "public"."sync_user_for_priority_twist";
-- Drop "sync_user_for_priority_twist_connection" function
DROP FUNCTION "public"."sync_user_for_priority_twist_connection";
