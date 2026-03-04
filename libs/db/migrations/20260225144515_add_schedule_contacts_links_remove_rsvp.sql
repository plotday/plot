-- Create "ensure_link_assignee_priority_contact" function
CREATE FUNCTION "public"."ensure_link_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the priority_id from the thread
    SELECT
        t.priority_id INTO v_priority_id
    FROM
        thread t
    WHERE
        t.id = NEW.thread_id;
    -- Only create priority_contact if assignee is a contact (not a priority_twist)
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
-- Create "link" table
CREATE TABLE "public"."link" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "thread_id" uuid NOT NULL,
  "source" text NULL,
  "source_created_at" timestamptz NOT NULL DEFAULT now(),
  "source_priority_root" public.ltree NULL,
  "author_id" uuid NULL,
  "twist_id" bigint NULL,
  "created_by" uuid NULL,
  "updated_by" integer NOT NULL DEFAULT 0,
  "sync_depth" integer NULL,
  "title" text NULL,
  "preview" text NULL,
  "assignee_id" uuid NULL,
  "type" text NULL,
  "status" text NULL,
  "actions" jsonb NULL,
  "meta" jsonb NULL,
  "embedding" public.halfvec(384) NULL,
  "match" jsonb NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "link_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_link_created_by" to table: "link"
CREATE INDEX "idx_link_created_by" ON "public"."link" ("created_by");
-- Create index "idx_link_source" to table: "link"
CREATE INDEX "idx_link_source" ON "public"."link" ("source") WHERE (source IS NOT NULL);
-- Create index "idx_link_thread_id" to table: "link"
CREATE INDEX "idx_link_thread_id" ON "public"."link" ("thread_id");
-- Create index "idx_link_updated_at" to table: "link"
CREATE INDEX "idx_link_updated_at" ON "public"."link" ("updated_at");
-- Create index "link_embedding_idx" to table: "link"
CREATE INDEX "link_embedding_idx" ON "public"."link" USING HNSW ("embedding" public.halfvec_cosine_ops);
-- Create index "link_source_priority_unique" to table: "link"
CREATE UNIQUE INDEX "link_source_priority_unique" ON "public"."link" ("source", "source_priority_root");
-- Set comment to column: "source" on table: "link"
COMMENT ON COLUMN "public"."link"."source" IS 'External source identifier for deduplication and sync. Used with source_priority_root for upsert behavior.';
-- Set comment to column: "source_created_at" on table: "link"
COMMENT ON COLUMN "public"."link"."source_created_at" IS 'When this link was originally created in its source system. Defaults to now() but can be set by twists.';
-- Set comment to column: "source_priority_root" on table: "link"
COMMENT ON COLUMN "public"."link"."source_priority_root" IS 'Root element of the priority path. Set by trigger when source is non-null. Used with source to ensure uniqueness per top-level priority.';
-- Set comment to column: "author_id" on table: "link"
COMMENT ON COLUMN "public"."link"."author_id" IS 'The actor to credit with creating this link. For links created by twists on behalf of contacts or users, this is the contact/user.';
-- Set comment to column: "twist_id" on table: "link"
COMMENT ON COLUMN "public"."link"."twist_id" IS 'The twist definition ID (twist_admin.id) that created this link. Null for user-created links.';
-- Set comment to column: "created_by" on table: "link"
COMMENT ON COLUMN "public"."link"."created_by" IS 'The user_id or priority_twist_id that actually created this link. Used for filtering callbacks and permissions.';
-- Set comment to column: "type" on table: "link"
COMMENT ON COLUMN "public"."link"."type" IS 'Source-defined type string (e.g., issue, pull_request, email, event). Free text, with structured registry in source linkTypes config.';
-- Set comment to column: "status" on table: "link"
COMMENT ON COLUMN "public"."link"."status" IS 'Source-defined status string (e.g., open, done, closed). Free text.';
-- Set comment to column: "match" on table: "link"
COMMENT ON COLUMN "public"."link"."match" IS 'The PickPriorityConfig used to automatically select this link''s priority. Null if priority was explicitly specified. Used when moving links to find similar links to move.';
-- Create trigger "ensure_link_assignee_priority_contact_trigger"
CREATE TRIGGER "ensure_link_assignee_priority_contact_trigger" AFTER INSERT OR UPDATE OF "assignee_id", "thread_id" ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_link_assignee_priority_contact"();
-- Create "sync_twist_for_link" function
CREATE FUNCTION "public"."sync_twist_for_link" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
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
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'create', v_create_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    -- Process UPDATE operations
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN thread t ON t.id = n.thread_id
            JOIN priority p_child ON p_child.id = t.priority_id
            JOIN priority p_parent ON p_child.path <@ p_parent.path
            JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            pct.archived_at IS NULL
            -- Track sync for the twist that created this link
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'link', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_link_insert"
CREATE TRIGGER "twist_sync_link_insert" AFTER INSERT ON "public"."link" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_link"();
-- Create trigger "set_link_created_at"
CREATE TRIGGER "set_link_created_at" BEFORE INSERT ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "set_link_source_priority_root" function
CREATE FUNCTION "public"."set_link_source_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path via the thread
        SELECT
            p.path INTO priority_path
        FROM
            public.thread t
            JOIN public.priority p ON p.id = t.priority_id
        WHERE
            t.id = NEW.thread_id;
        -- Extract the root element (first segment) of the priority path
        IF priority_path IS NOT NULL THEN
            NEW.source_priority_root := subpath (priority_path, 0, 1);
        END IF;
    ELSE
        -- Clear source_priority_root when source is null
        NEW.source_priority_root := NULL;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_link_source_priority_root_trigger"
CREATE TRIGGER "set_link_source_priority_root_trigger" BEFORE INSERT OR UPDATE OF "source", "thread_id" ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."set_link_source_priority_root"();
-- Create trigger "set_link_updated_at"
CREATE TRIGGER "set_link_updated_at" BEFORE INSERT OR UPDATE ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_link_update"
CREATE TRIGGER "twist_sync_link_update" AFTER UPDATE ON "public"."link" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_link"();
-- Create "bump_schedule_updated_at" function
CREATE FUNCTION "public"."bump_schedule_updated_at" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    UPDATE schedule
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT schedule_id FROM new_table);
    RETURN NULL;
END;
$$;
-- Drop "schedule" view
DROP VIEW "user"."schedule";
-- Modify "schedule" table
ALTER TABLE "public"."schedule" ADD CONSTRAINT "schedule_thread_xor_link" CHECK (((thread_id IS NOT NULL) AND (link_id IS NULL)) OR ((thread_id IS NULL) AND (link_id IS NOT NULL))), ALTER COLUMN "thread_id" DROP NOT NULL, ADD COLUMN "link_id" uuid NULL, ADD CONSTRAINT "schedule_link_id_fkey" FOREIGN KEY ("link_id") REFERENCES "public"."link" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Create index "idx_schedule_link_id" to table: "schedule"
CREATE INDEX "idx_schedule_link_id" ON "public"."schedule" ("link_id");
-- Create index "schedule_link_occurrence_unique" to table: "schedule"
CREATE UNIQUE INDEX "schedule_link_occurrence_unique" ON "public"."schedule" ("link_id", "occurrence") WHERE (occurrence IS NOT NULL);
-- Create index "schedule_link_user_unique" to table: "schedule"
CREATE UNIQUE INDEX "schedule_link_user_unique" ON "public"."schedule" ("link_id", "user_id") WHERE ((user_id IS NOT NULL) AND (occurrence IS NULL));
-- Create "schedule_contact" table
CREATE TABLE "public"."schedule_contact" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "archived_at" timestamptz NULL,
  "schedule_id" uuid NOT NULL,
  "contact_id" uuid NOT NULL,
  "status" text NULL,
  "role" text NOT NULL DEFAULT 'required',
  PRIMARY KEY ("id"),
  CONSTRAINT "schedule_contact_unique" UNIQUE ("schedule_id", "contact_id"),
  CONSTRAINT "schedule_contact_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contact" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "schedule_contact_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedule" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "schedule_contact_role_check" CHECK (role = ANY (ARRAY['organizer'::text, 'required'::text, 'optional'::text])),
  CONSTRAINT "schedule_contact_status_check" CHECK (status = ANY (ARRAY['attend'::text, 'skip'::text]))
);
-- Create index "idx_schedule_contact_contact_id" to table: "schedule_contact"
CREATE INDEX "idx_schedule_contact_contact_id" ON "public"."schedule_contact" ("contact_id");
-- Create index "idx_schedule_contact_schedule_id" to table: "schedule_contact"
CREATE INDEX "idx_schedule_contact_schedule_id" ON "public"."schedule_contact" ("schedule_id");
-- Create index "idx_schedule_contact_updated_at" to table: "schedule_contact"
CREATE INDEX "idx_schedule_contact_updated_at" ON "public"."schedule_contact" ("updated_at");
-- Create trigger "schedule_contact_bump_schedule_insert"
CREATE TRIGGER "schedule_contact_bump_schedule_insert" AFTER INSERT ON "public"."schedule_contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_schedule_updated_at"();
-- Create trigger "set_schedule_contact_created_at"
CREATE TRIGGER "set_schedule_contact_created_at" BEFORE INSERT ON "public"."schedule_contact" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_schedule_contact_updated_at"
CREATE TRIGGER "set_schedule_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."schedule_contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "schedule_contact_bump_schedule_update"
CREATE TRIGGER "schedule_contact_bump_schedule_update" AFTER UPDATE ON "public"."schedule_contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_schedule_updated_at"();
-- Create "upsert_schedule_contacts" function
CREATE FUNCTION "user"."upsert_schedule_contacts" ("user_id" uuid, "p_schedule_id" uuid, "p_contacts" jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_contact jsonb;
    v_contact_id uuid;
    v_status text;
    v_role text;
    v_archived boolean;
    v_priority_id uuid;
BEGIN
    -- Validate user has access to the schedule's thread's priority
    SELECT a.priority_id INTO v_priority_id
    FROM schedule s
    JOIN thread a ON a.id = s.thread_id
    WHERE s.id = p_schedule_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Schedule not found';
    END IF;

    IF NOT "user".has_priority_access(user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this schedule';
    END IF;

    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        v_contact_id := (v_contact ->> 'contact_id')::uuid;
        v_status := v_contact ->> 'status';
        v_role := v_contact ->> 'role';
        v_archived := COALESCE((v_contact ->> 'archived')::boolean, false);

        INSERT INTO schedule_contact (schedule_id, contact_id, status, role, archived_at)
        VALUES (
            p_schedule_id,
            v_contact_id,
            v_status,
            COALESCE(v_role, 'required'),
            CASE WHEN v_archived THEN now() ELSE NULL END
        )
        ON CONFLICT (schedule_id, contact_id)
        DO UPDATE SET
            status = CASE
                WHEN v_contact ? 'status' THEN EXCLUDED.status
                ELSE schedule_contact.status
            END,
            role = CASE
                WHEN v_contact ? 'role' THEN EXCLUDED.role
                ELSE schedule_contact.role
            END,
            archived_at = CASE
                WHEN v_archived THEN COALESCE(schedule_contact.archived_at, now())
                ELSE NULL
            END;

        -- Ensure priority_contact exists for the contact
        INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id) DO NOTHING;
    END LOOP;
END;
$$;
-- Modify "find_matching_threads_scored" function
CREATE OR REPLACE FUNCTION "public"."find_matching_threads_scored" ("query_embedding" text, "created_by_id" uuid, "required_filters" jsonb DEFAULT '{}', "scored_fields" jsonb DEFAULT '{}', "thread_data" jsonb DEFAULT '{}', "similarity_threshold" double precision DEFAULT 0.7) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "total_score" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY WITH filtered_links AS (
        -- First filter by required exact matches on link fields
        SELECT
            l.id AS link_id,
            l.thread_id,
            t.priority_id,
            COALESCE(l.title, t.title) AS title,
            l.type,
            l.meta,
            l.embedding
        FROM
            public.link l
            JOIN public.thread t ON t.id = l.thread_id
        WHERE
            l.created_by = created_by_id
            AND t.archived_at IS NULL
            -- Content similarity filter (when content is required)
            -- Skip if query_embedding is null/empty (embedding generation failed)
            AND ((required_filters ? 'content'
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]'
                    AND l.embedding IS NOT NULL
                    AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND l.type = (thread_data ->> 'type'))
                OR NOT (required_filters ? 'type'))
            -- Meta field exact matches (when meta.field is required)
            AND (
                -- Check all required meta fields match
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        jsonb_object_keys(required_filters) AS key
                    WHERE
                        key LIKE 'meta.%'
                        AND (l.meta IS NULL
                            OR l.meta ->> substring(key FROM 6) IS DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6))))
),
scored_links AS (
    -- Calculate scores for each matching link
    SELECT
        fl.thread_id AS id,
        fl.priority_id,
        fl.title,
        -- Sum up all scores
        (
            -- Content similarity score (skip if query_embedding is null/empty)
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fl.embedding IS NOT NULL
                    AND query_embedding IS NOT NULL
                    AND query_embedding <> ''
                    AND query_embedding <> '[]' THEN
                    (scored_fields ->> 'content')::float * (1 - (fl.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fl.type = (thread_data ->> 'type') THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                    END
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fl.meta IS NOT NULL
                                AND fl.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM thread_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_links fl
)
SELECT
    sl.id,
    sl.priority_id,
    sl.title,
    sl.total_score
FROM
    scored_links sl
WHERE
    sl.total_score > 0
ORDER BY
    sl.total_score DESC
LIMIT 1;
END;
$$;
-- Modify "find_similar_threads" function
CREATE OR REPLACE FUNCTION "public"."find_similar_threads" ("query_embedding" text, "created_by_id" uuid, "similarity_threshold" double precision DEFAULT 0.5, "match_limit" integer DEFAULT 1) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        l.thread_id AS id,
        t.priority_id,
        COALESCE(l.title, t.title) AS title,
        1 - (l.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.link l
        JOIN public.thread t ON t.id = l.thread_id
    WHERE
        l.created_by = created_by_id
        AND l.embedding IS NOT NULL
        AND t.archived_at IS NULL
        AND (1 - (l.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        l.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;
-- Modify "update_thread_tags" function
CREATE OR REPLACE FUNCTION "user"."update_thread_tags" ("user_id" uuid, "p_thread_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
BEGIN
    -- Validate that thread_id is provided
    IF p_thread_id IS NULL THEN
        RAISE EXCEPTION 'p_thread_id must be provided';
    END IF;
    -- Validate access to the thread's priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        thread a
    WHERE
        a.id = p_thread_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Prevent insertion of computed tags (tag_id 1-99)
            -- Computed tags should only exist as calculated values
            IF current_tag_type = 'compute' THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from thread state', tag_id_int;
            END IF;
            -- For count tags, enforce that users can only modify their own tags
            -- p_actor_id should match the authenticated user's contact_id
            -- Note: RLS policies already enforce this, but we validate explicitly for clarity
            IF current_tag_type = 'count' THEN
                -- Validate p_actor_id matches current user's contact_id
                IF p_actor_id != "user".user_contact_id (user_id) THEN
                    RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', tag_id_int;
                END IF;
            END IF;
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO thread_tag (actor_id, thread_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_thread_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, thread_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on threads
                IF EXISTS (
                    SELECT
                        1
                    FROM
                        contact
                    WHERE
                        id = p_actor_id) THEN
                INSERT INTO priority_contact (priority_id, contact_id)
                SELECT
                    a.priority_id,
                    p_actor_id
                FROM
                    thread a
                WHERE
                    a.id = p_thread_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    thread_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    thread_id = p_thread_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Modify "upsert_schedule" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule" ("user_id" uuid, "p_schedule" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."schedule" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_thread_id uuid;
    v_link_id uuid;
    v_priority_id uuid;
    v_schedule_user_id uuid;
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    v_result schedule;
BEGIN
    -- Extract fields
    v_id := COALESCE((p_schedule ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_schedule ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_link_id := COALESCE((p_schedule ->> 'link_id')::uuid, (p_defaults ->> 'link_id')::uuid);
    v_schedule_user_id := COALESCE((p_schedule ->> 'user_id')::uuid, (p_defaults ->> 'user_id')::uuid);

    -- Resolve thread_id/link_id from existing schedule if updating
    IF v_thread_id IS NULL AND v_link_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            s.thread_id, s.link_id INTO v_thread_id, v_link_id
        FROM
            schedule s
        WHERE
            s.id = v_id;
    END IF;

    -- Must have either thread_id or link_id
    IF v_thread_id IS NULL AND v_link_id IS NULL THEN
        RAISE EXCEPTION 'thread_id or link_id must be provided';
    END IF;

    -- Look up priority for access check
    IF v_thread_id IS NOT NULL THEN
        SELECT
            a.priority_id INTO v_priority_id
        FROM
            thread a
        WHERE
            a.id = v_thread_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
    ELSIF v_link_id IS NOT NULL THEN
        SELECT
            t.priority_id INTO v_priority_id
        FROM
            link l
            JOIN thread t ON t.id = l.thread_id
        WHERE
            l.id = v_link_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Link not found';
        END IF;
    END IF;

    PERFORM "user".assert_priority_access(upsert_schedule.user_id, v_priority_id);

    -- Per-user schedules can only be created/modified by the owning user
    IF v_schedule_user_id IS NOT NULL AND v_schedule_user_id != upsert_schedule.user_id THEN
        RAISE EXCEPTION 'Cannot create/modify per-user schedule for another user';
    END IF;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Handle recurrence_exdates array conversion from JSONB
    IF p_schedule ? 'recurrence_exdates' AND jsonb_typeof(p_schedule -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;

    -- Handle add/remove exdates
    IF p_schedule ? 'recurrence_exdates_add' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_schedule ? 'recurrence_exdates_remove' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;

    -- Perform the upsert
    INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, archived_at)
        VALUES (
            v_id,
            v_thread_id,
            v_link_id,
            v_schedule_user_id,
            CASE WHEN v_schedule_user_id IS NOT NULL THEN
                COALESCE((p_schedule ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first())
            ELSE
                NULL
            END,
            COALESCE((p_schedule ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange),
            COALESCE((p_schedule ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            COALESCE(p_schedule ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'),
            COALESCE((p_schedule ->> 'duration')::interval, (p_defaults ->> 'duration')::interval),
            v_recurrence_exdates,
            COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence'),
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            at = CASE WHEN p_schedule ? 'at' THEN
                (p_schedule ->> 'at')::tstzrange
            ELSE
                schedule.at
            END,
            "on" = CASE WHEN p_schedule ? 'on' THEN
                (p_schedule ->> 'on')::daterange
            ELSE
                schedule."on"
            END,
            recurrence_rule = CASE WHEN p_schedule ? 'recurrence_rule' THEN
                p_schedule ->> 'recurrence_rule'
            ELSE
                schedule.recurrence_rule
            END,
            duration = CASE WHEN p_schedule ? 'duration' THEN
                (p_schedule ->> 'duration')::interval
            ELSE
                schedule.duration
            END,
            recurrence_exdates = CASE WHEN p_schedule ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(schedule.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                schedule.recurrence_exdates
            END,
            "order" = CASE WHEN p_schedule ? 'order' THEN
                (p_schedule ->> 'order')::double precision
            ELSE
                schedule."order"
            END,
            archived_at = CASE WHEN p_schedule ? 'archived_at' THEN
                (p_schedule ->> 'archived_at')::timestamptz
            ELSE
                schedule.archived_at
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Create "upsert_link" function
CREATE FUNCTION "user"."upsert_link" ("user_id" uuid, "p_link" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."link" LANGUAGE plpgsql AS $$
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
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_link ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_link ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_source := p_link ->> 'source';
    v_created_by := COALESCE((p_link ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    v_author_id := COALESCE((p_link ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);

    -- DERIVE source_priority_root from thread's priority when source exists
    IF p_link ? 'source_priority_root' AND (p_link ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_link ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL AND v_thread_id IS NOT NULL THEN
        SELECT
            subpath (p.path, 0, 1) INTO v_source_priority_root
        FROM
            thread t
            JOIN priority p ON p.id = t.priority_id
        WHERE
            t.id = v_thread_id;
    END IF;

    -- Resolve id from source if not provided (for twist-created links)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            l.id INTO v_id
        FROM
            link l
        WHERE
            l.source = v_source
            AND l.source_priority_root = v_source_priority_root;
    END IF;

    -- Generate id if still not resolved
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

    -- Get priority_id from thread for access check
    SELECT
        t.priority_id INTO v_priority_id
    FROM
        thread t
    WHERE
        t.id = v_thread_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_link.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_link.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    -- DERIVE twist_id from created_by (priority_twist_id)
    IF p_link ? 'twist_id' AND (p_link ->> 'twist_id') IS NOT NULL THEN
        v_twist_id := (p_link ->> 'twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_twist_id
        FROM
            priority_twist pt
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
        actions, meta, embedding, match)
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
            COALESCE((p_link ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec),
            COALESCE(p_link -> 'match', p_defaults -> 'match'))
    ON CONFLICT (id)
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
            twist_id = v_twist_id
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Create "priority_twist_link_update" view
CREATE VIEW "public"."priority_twist_link_update" (
  "priority_twist_id",
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
) AS SELECT l.created_by AS priority_twist_id,
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
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread t ON t.priority_id = pc.id
     JOIN public.link l ON l.thread_id = t.id
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE t.draft = false AND pt.id = l.created_by AND l.updated_at > l.created_at AND public.updated_by_uuid(pt.id) <> l.updated_by::numeric AND pt.archived_at IS NULL AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "link_x" view
CREATE VIEW "public"."link_x" (
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "source_priority_root",
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
  "embedding",
  "match",
  "priority_id",
  "priority_path"
) AS SELECT l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
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
    l.embedding,
    l.match,
    t.priority_id,
    p.path AS priority_path
   FROM public.link l
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.priority p ON p.id = t.priority_id;
-- Create "link" view
CREATE VIEW "user"."link" (
  "user_id",
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
  "priority_path"
) AS SELECT upe.user_id,
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
    l.priority_id,
    l.priority_path
   FROM public.link_x l
     JOIN "user".priority_expanded upe ON l.priority_id = upe.priority_id;
-- Create "schedule" view
CREATE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT upe.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.thread t_thread ON t_thread.id = s.thread_id
     LEFT JOIN public.link l ON l.id = s.link_id
     LEFT JOIN public.thread t_link ON t_link.id = l.thread_id
     JOIN "user".priority_expanded upe ON upe.priority_id = COALESCE(t_thread.priority_id, t_link.priority_id)
  WHERE s.user_id IS NULL OR s.user_id = upe.user_id;
-- Drop "is_rsvp_tag" function
DROP FUNCTION "public"."is_rsvp_tag";
