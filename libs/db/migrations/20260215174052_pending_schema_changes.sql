-- Set comment to column: "author_id" on table: "activity"
COMMENT ON COLUMN "public"."activity"."author_id" IS 'The actor to credit with creating this activity. For activities created by twists on behalf of contacts or users, this is the contact/user. For activities created directly by users or twists, this is the user/twist ID.';
-- Set comment to column: "created_by" on table: "activity"
COMMENT ON COLUMN "public"."activity"."created_by" IS 'The user_id or priority_twist_id that actually created this activity. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';
-- Set comment to column: "source" on table: "activity"
COMMENT ON COLUMN "public"."activity"."source" IS 'External source identifier for deduplication and sync. Provided as a top-level field in the Activity type (not stored in meta). Indexed for efficient lookups. Used with source_priority_root for upsert behavior.';
-- Set comment to column: "created_by_twist_id" on table: "activity"
COMMENT ON COLUMN "public"."activity"."created_by_twist_id" IS 'The twist definition ID (twist_admin.id) that created this activity. Null for user-created activities. No longer used in unique constraint (replaced by source_priority_root).';
-- Set comment to column: "pick_priority" on table: "activity"
COMMENT ON COLUMN "public"."activity"."pick_priority" IS 'The PickPriorityConfig used to automatically select this activity''s priority. Null if priority was explicitly specified. Used when moving activities to find similar activities to move. Not exposed to app or API.';
-- Set comment to column: "last_note_created_at" on table: "activity"
COMMENT ON COLUMN "public"."activity"."last_note_created_at" IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for unread status in user_activity and user_priority_unread views.';
-- Set comment to column: "source_created_at" on table: "activity"
COMMENT ON COLUMN "public"."activity"."source_created_at" IS 'When this activity was originally created in its source system (e.g., GitHub issue creation date, email sent date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the activity entered Plot''s database.';
-- Set comment to column: "source_priority_root" on table: "activity"
COMMENT ON COLUMN "public"."activity"."source_priority_root" IS 'Root element of the priority path (e.g., first segment of the ltree). Set by trigger when source is non-null. Used with source to ensure uniqueness per top-level priority.';
-- Set comment to column: "last_note_source_created_at" on table: "activity"
COMMENT ON COLUMN "public"."activity"."last_note_source_created_at" IS 'Cached MAX(note.source_created_at) for non-draft, non-archived notes. Maintained by trigger. Used for display, sorting, and range_at computation in user_activity view.';
-- Create "ensure_assignee_priority_contact" function
CREATE FUNCTION "public"."ensure_assignee_priority_contact" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    IF NEW.assignee_id IS NULL THEN
        RETURN NULL;
    END IF;
    -- Only create priority_contact if assignee is a contact (not a priority_twist)
    IF EXISTS (
        SELECT
            1
        FROM
            contact
        WHERE
            id = NEW.assignee_id) THEN
    INSERT INTO priority_contact (priority_id, contact_id)
        VALUES (NEW.priority_id, NEW.assignee_id)
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "ensure_assignee_priority_contact_trigger"
CREATE TRIGGER "ensure_assignee_priority_contact_trigger" AFTER INSERT OR UPDATE OF "assignee_id", "priority_id" ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_assignee_priority_contact"();
-- Create "sync_twist_for_activity" function
CREATE FUNCTION "public"."sync_twist_for_activity" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
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
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft activities (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft rows are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this activity
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'activity', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for the twist that created this activity
                AND n.created_by = pct.id
            ORDER BY
                pct.id LOOP
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'activity', 'create', v_create_timestamp)
                    ON CONFLICT (priority_twist_id, entity, operation)
                        DO UPDATE SET
                            last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published activities)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority p_child ON p_child.id = n.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for the twist that created this activity
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_activity_insert"
CREATE TRIGGER "twist_sync_activity_insert" AFTER INSERT ON "public"."activity" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_activity"();
-- Create "priority_child" view
CREATE VIEW "public"."priority_child" (
  "priority_id",
  "child_id",
  "archived_at"
) AS SELECT p.id AS priority_id,
    c.id AS child_id,
    c.archived_at
   FROM public.priority p
     JOIN public.priority c ON c.path OPERATOR(public.<@) p.path;
-- Create "priority_settings_inherited" view
CREATE VIEW "public"."priority_settings_inherited" (
  "user_id",
  "priority_id",
  "path",
  "pomodoro",
  "color"
) AS WITH inherited_sources AS (
         SELECT ps.user_id,
            p.id AS priority_id,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            0 AS source_type,
                CASE
                    WHEN public.nlevel(p.path) > public.nlevel(parent.path) AND public.subpath(p.path, public.nlevel(parent.path)) OPERATOR(public.<>) ''::public.ltree THEN ps.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(parent.path))
                    ELSE ps.path
                END AS path,
            ps.pomodoro,
            ps.color
           FROM public.priority_settings ps
             JOIN public.priority parent ON ps.priority_id = parent.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) parent.path
          WHERE ps.path IS NOT NULL OR ps.pomodoro IS NOT NULL OR ps.color IS NOT NULL
        UNION ALL
         SELECT pu.user_id,
            p.id AS priority_id,
            public.nlevel(p.path) - public.nlevel(parent.path) AS distance,
            1 AS source_type,
            NULL::public.ltree AS path,
            NULL::integer AS pomodoro,
            parent.color
           FROM public.priority_user pu
             JOIN public.priority root ON pu.priority_id = root.id
             JOIN public.priority p ON p.path OPERATOR(public.<@) root.path
             JOIN public.priority parent ON p.path OPERATOR(public.<@) parent.path
          WHERE parent.color IS NOT NULL
        )
 SELECT DISTINCT ON (user_id, priority_id) user_id,
    priority_id,
    path,
    pomodoro,
    color
   FROM inherited_sources
  ORDER BY user_id, priority_id, distance, source_type;
-- Create "priority_expanded" view
CREATE VIEW "user"."priority_expanded" (
  "user_id",
  "priority_id",
  "joined_at",
  "archived_at",
  "path"
) AS WITH base AS (
         SELECT pu.user_id,
            c.child_id AS priority_id,
            min(pu.created_at) AS joined_at,
            LEAST(min(pu.archived_at), min(c.archived_at)) AS archived_at
           FROM public.priority_user pu
             JOIN public.priority_child c ON pu.priority_id = c.priority_id
          GROUP BY pu.user_id, c.child_id
        )
 SELECT b.user_id,
    b.priority_id,
    b.joined_at,
    b.archived_at,
        CASE
            WHEN inherited_settings.path IS NOT NULL THEN inherited_settings.path
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            WHEN parent_inherited_settings.path IS NOT NULL THEN parent_inherited_settings.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(p.path) - 1, 1)::text::public.ltree
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path
   FROM base b
     LEFT JOIN public.priority p ON p.id = b.priority_id
     LEFT JOIN public.priority_user pu_root ON b.user_id = pu_root.user_id AND pu_root.personal = true
     LEFT JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     LEFT JOIN public.priority_settings_inherited inherited_settings ON inherited_settings.user_id = b.user_id AND inherited_settings.priority_id = b.priority_id
     LEFT JOIN public.priority parent_p ON public.nlevel(p.path) > 1 AND parent_p.path OPERATOR(public.=) public.subpath(p.path, 0, public.nlevel(p.path) - 1)
     LEFT JOIN public.priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = b.user_id AND parent_p.id = parent_inherited_settings.priority_id;
-- Create "sync_user_for_activity" function
CREATE FUNCTION "public"."sync_user_for_activity" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to affected priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_activity_insert"
CREATE TRIGGER "user_sync_activity_insert" AFTER INSERT ON "public"."activity" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity"();
-- Create "update_author_and_created_by" function
CREATE FUNCTION "public"."update_author_and_created_by" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.created_by IS NULL THEN
        RAISE EXCEPTION 'created_by must be provided';
    END IF;
    IF NEW.author_id IS NULL THEN
        NEW.author_id := NEW.created_by;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_activity_author_and_created_by"
CREATE TRIGGER "set_activity_author_and_created_by" BEFORE INSERT ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."update_author_and_created_by"();
-- Create "set_created_at" function
CREATE FUNCTION "public"."set_created_at" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_at = now();
    RETURN NEW;
END;
$$;
-- Create trigger "set_activity_created_at"
CREATE TRIGGER "set_activity_created_at" BEFORE INSERT ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "set_activity_order_on_start" function
CREATE FUNCTION "public"."set_activity_order_on_start" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- If activity has a start time (at or on) but no explicit order,
    -- set order to current timestamp for stable sorting
    IF (NEW.at IS NOT NULL OR NEW."on" IS NOT NULL) AND NEW."order" IS NULL THEN
        NEW."order" := public.order_first ();
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_activity_order_on_start_trigger"
CREATE TRIGGER "set_activity_order_on_start_trigger" BEFORE INSERT OR UPDATE ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."set_activity_order_on_start"();
-- Create "set_activity_source_priority_root" function
CREATE FUNCTION "public"."set_activity_source_priority_root" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    priority_path ltree;
BEGIN
    -- Only set source_priority_root when source is non-null
    IF NEW.source IS NOT NULL THEN
        -- Get the priority path
        SELECT
            p.path INTO priority_path
        FROM
            public.priority p
        WHERE
            p.id = NEW.priority_id;
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
-- Create trigger "set_activity_source_priority_root_trigger"
CREATE TRIGGER "set_activity_source_priority_root_trigger" BEFORE INSERT OR UPDATE OF "priority_id", "source" ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."set_activity_source_priority_root"();
-- Create "update_updated_at" function
CREATE FUNCTION "public"."update_updated_at" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;
-- Create trigger "set_activity_updated_at"
CREATE TRIGGER "set_activity_updated_at" BEFORE INSERT OR UPDATE ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_activity_update"
CREATE TRIGGER "twist_sync_activity_update" AFTER UPDATE ON "public"."activity" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_activity"();
-- Create trigger "user_sync_activity_update"
CREATE TRIGGER "user_sync_activity_update" AFTER UPDATE ON "public"."activity" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity"();
-- Create "enforce_draft_rules" function
CREATE FUNCTION "public"."enforce_draft_rules" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Prevent unpublishing: draft cannot go from false to true
    IF OLD.draft = FALSE AND NEW.draft = TRUE THEN
        RAISE EXCEPTION 'Cannot change draft from false to true';
    END IF;
    -- Update created_at when publishing (draft: true -> false)
    IF OLD.draft = TRUE AND NEW.draft = FALSE THEN
        NEW.created_at = now();
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "enforce_activity_draft_rules_trigger"
CREATE TRIGGER "enforce_activity_draft_rules_trigger" BEFORE UPDATE ON "public"."activity" FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft) EXECUTE FUNCTION "public"."enforce_draft_rules"();
-- Create "protect_activity_created_by" function
CREATE FUNCTION "public"."protect_activity_created_by" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
            -- Derive created_by_twist_id from new created_by
            SELECT
                pt.twist_id INTO NEW.created_by_twist_id
            FROM
                priority_twist pt
            WHERE
                pt.id = NEW.created_by;
        END IF;
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
        NEW.created_by_twist_id := OLD.created_by_twist_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "protect_activity_created_by_trigger"
CREATE TRIGGER "protect_activity_created_by_trigger" BEFORE UPDATE ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."protect_activity_created_by"();
-- Set comment to column: "occurrence" on table: "activity_exception"
COMMENT ON COLUMN "public"."activity_exception"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';
-- Create trigger "set_activity_exception_created_at"
CREATE TRIGGER "set_activity_exception_created_at" BEFORE INSERT ON "public"."activity_exception" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_activity_exception_updated_at"
CREATE TRIGGER "set_activity_exception_updated_at" BEFORE INSERT OR UPDATE ON "public"."activity_exception" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "sync_user_for_activity_read" function
CREATE FUNCTION "public"."sync_user_for_activity_read" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the reading user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity_read', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_activity_read_insert"
CREATE TRIGGER "user_sync_activity_read_insert" AFTER INSERT ON "public"."activity_read" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_read"();
-- Create trigger "set_activity_read_updated_at"
CREATE TRIGGER "set_activity_read_updated_at" BEFORE INSERT OR UPDATE ON "public"."activity_read" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_activity_read_update"
CREATE TRIGGER "user_sync_activity_read_update" AFTER UPDATE ON "public"."activity_read" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_read"();
-- Set comment to column: "occurrence" on table: "activity_tag"
COMMENT ON COLUMN "public"."activity_tag"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';
-- Create "sync_twist_for_activity_tag" function
CREATE FUNCTION "public"."sync_twist_for_activity_tag" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected activities
    -- Only consider tags on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this activity
        AND a.created_by = pct.id
    ORDER BY
        pct.id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'activity', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_activity_tag_insert"
CREATE TRIGGER "twist_sync_activity_tag_insert" AFTER INSERT ON "public"."activity_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_activity_tag"();
-- Create "sync_user_for_activity_tag" function
CREATE FUNCTION "public"."sync_user_for_activity_tag" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_activity_tag_insert"
CREATE TRIGGER "user_sync_activity_tag_insert" AFTER INSERT ON "public"."activity_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_tag"();
-- Create trigger "set_activity_tag_updated_at"
CREATE TRIGGER "set_activity_tag_updated_at" BEFORE INSERT OR UPDATE ON "public"."activity_tag" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_activity_tag_update"
CREATE TRIGGER "twist_sync_activity_tag_update" AFTER UPDATE ON "public"."activity_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_activity_tag"();
-- Create trigger "user_sync_activity_tag_update"
CREATE TRIGGER "user_sync_activity_tag_update" AFTER UPDATE ON "public"."activity_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_tag"();
-- Create "get_domain" function
CREATE FUNCTION "public"."get_domain" ("email" text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
BEGIN
    RETURN lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
END;
$$;
-- Create "organization" function
CREATE FUNCTION "public"."organization" ("public"."contact") RETURNS SETOF "public"."organization" LANGUAGE sql STABLE AS $$
SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.name = get_domain ($1.email)
$$;
-- Create "insert_domain" function
CREATE FUNCTION "public"."insert_domain" ("email" text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    domain_name text := get_domain (email);
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "name" = domain_name;
    IF NOT FOUND THEN
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "name")
            VALUES (org_id, domain_name);
    END IF;
    RETURN domain_id;
END;
$$;
-- Create "insert_email_domain" function
CREATE FUNCTION "public"."insert_email_domain" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM
        public.insert_domain (NEW.email);
    RETURN NEW;
END;
$$;
-- Create trigger "on_contact_created"
CREATE TRIGGER "on_contact_created" AFTER INSERT ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."insert_email_domain"();
-- Create "sync_user_for_contact" function
CREATE FUNCTION "public"."sync_user_for_contact" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Contact changes affect all users with access to priorities where this contact is linked (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN priority_contact pc ON pc.contact_id = n.id
        JOIN "user".priority_expanded upe ON upe.priority_id = pc.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_contact_insert"
CREATE TRIGGER "user_sync_contact_insert" AFTER INSERT ON "public"."contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_contact"();
-- Create trigger "set_contact_created_at"
CREATE TRIGGER "set_contact_created_at" BEFORE INSERT ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_contact_updated_at"
CREATE TRIGGER "set_contact_updated_at" BEFORE INSERT OR UPDATE ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_contact_update"
CREATE TRIGGER "user_sync_contact_update" AFTER UPDATE ON "public"."contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_contact"();
-- Create "contact_clear_primary_on_unlink" function
CREATE FUNCTION "public"."contact_clear_primary_on_unlink" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS NULL AND OLD.user_id IS NOT NULL AND NEW."primary" = true THEN
        NEW."primary" := false;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "on_contact_user_unlinked"
CREATE TRIGGER "on_contact_user_unlinked" BEFORE UPDATE ON "public"."contact" FOR EACH ROW WHEN ((old.user_id IS NOT NULL) AND (new.user_id IS NULL)) EXECUTE FUNCTION "public"."contact_clear_primary_on_unlink"();
-- Create trigger "set_cost_created_at"
CREATE TRIGGER "set_cost_created_at" BEFORE INSERT ON "public"."cost" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_cost_updated_at"
CREATE TRIGGER "set_cost_updated_at" BEFORE INSERT OR UPDATE ON "public"."cost" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Set comment to column: "author_id" on table: "note"
COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by twists on behalf of contacts or users, this is the contact/user. For notes created directly by users or twists, this is the user/twist ID.';
-- Set comment to column: "created_by" on table: "note"
COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or priority_twist_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';
-- Set comment to column: "mentions" on table: "note"
COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of actor IDs (user_id, contact_id, or priority_twist_id) that are mentioned in this note via @-mentions.';
-- Set comment to column: "source_created_at" on table: "note"
COMMENT ON COLUMN "public"."note"."source_created_at" IS 'When this note was originally created in its source system (e.g., email sent date, comment creation date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the note entered Plot''s database.';
-- Set comment to column: "key" on table: "note"
COMMENT ON COLUMN "public"."note"."key" IS 'External identifier for deduplication and sync within an activity. Provided as a top-level field in the Note type. Indexed for efficient lookups. Used with activity_id for upsert behavior, allowing notes to be idempotently created or updated by external key (e.g., "description" for Jira issue descriptions).';
-- Create "update_activity_on_note_change" function
CREATE FUNCTION "public"."update_activity_on_note_change" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the activity read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this activity to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.activity_id::text));

        -- Upsert activity_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO activity_read (user_id, activity_id, read_at)
        SELECT
            NEW.created_by,
            NEW.activity_id,
            NEW.created_at
        WHERE
            -- Only insert if created_by is an actual user from public."user"
            EXISTS (
                SELECT
                    1
                FROM
                    public."user"
                WHERE
                    id = NEW.created_by)
            AND NOT EXISTS (
                -- Check if any other user created notes since this user's last read_at
                SELECT
                    1
                FROM
                    note n
                LEFT JOIN activity_read ar ON ar.user_id = NEW.created_by
                    AND ar.activity_id = NEW.activity_id
            WHERE
                n.activity_id = NEW.activity_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            activity_id)
            DO UPDATE SET
                read_at = NEW.created_at,
                updated_at = now()
            WHERE
                -- Only update if still no other users have notes since current read_at
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE
                        n.activity_id = NEW.activity_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > activity_read.read_at);
        -- Update activity's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            activity
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.activity_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Create trigger "update_activity_last_note_created_at_trigger"
CREATE TRIGGER "update_activity_last_note_created_at_trigger" AFTER DELETE OR INSERT ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."update_activity_on_note_change"();
-- Create "sync_twist_for_note" function
CREATE FUNCTION "public"."sync_twist_for_note" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft activities are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
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
            JOIN activity a ON a.id = n.activity_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft activities
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
        RETURN NULL;
    END IF;
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: track sync state for twists that created activity OR are mentioned
    -- Split into separate branches to avoid referencing old_table during INSERT
    IF v_create_timestamp IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            -- INSERT: no old_table reference, all non-draft notes on non-draft activities are creates
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN activity a ON a.id = n.activity_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for twists that created activity OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.activity_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        ELSE
            -- UPDATE (publishing draft): can reference old_table for draft true→false check
            FOR v_priority_twist_id IN SELECT DISTINCT
                pct.id
            FROM
                new_table n
                JOIN old_table o ON o.id = n.id
                JOIN activity a ON a.id = n.activity_id
                JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
            WHERE
                o.draft = TRUE
                AND n.draft = FALSE
                AND a.draft = FALSE
                AND pct.archived_at IS NULL
                -- Track sync for twists that created activity OR are mentioned anywhere in thread
                AND (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.activity_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
                    ORDER BY
                        pct.id LOOP
                        INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                            VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
                        ON CONFLICT (priority_twist_id, entity, operation)
                            DO UPDATE SET
                                last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                    END LOOP;
        END IF;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: track sync state for twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
            JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Track sync for note creator
            AND n.created_by = pct.id
        ORDER BY
            pct.id LOOP
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', 'update', v_update_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
            END LOOP;
    END IF;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_note_insert"
CREATE TRIGGER "twist_sync_note_insert" AFTER INSERT ON "public"."note" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note"();
-- Create "sync_user_for_note" function
CREATE FUNCTION "public"."sync_user_for_note" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_note_insert"
CREATE TRIGGER "user_sync_note_insert" AFTER INSERT ON "public"."note" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_note"();
-- Create trigger "set_note_author_and_created_by"
CREATE TRIGGER "set_note_author_and_created_by" BEFORE INSERT ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."update_author_and_created_by"();
-- Create trigger "set_note_created_at"
CREATE TRIGGER "set_note_created_at" BEFORE INSERT ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_note_updated_at"
CREATE TRIGGER "set_note_updated_at" BEFORE INSERT OR UPDATE ON "public"."note" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_note_update"
CREATE TRIGGER "twist_sync_note_update" AFTER UPDATE ON "public"."note" REFERENCING OLD TABLE AS "old_table" NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note"();
-- Create trigger "update_activity_last_note_created_at_on_status_change"
CREATE TRIGGER "update_activity_last_note_created_at_on_status_change" AFTER UPDATE OF "archived_at", "draft" ON "public"."note" FOR EACH ROW WHEN ((old.draft IS DISTINCT FROM new.draft) OR (old.archived_at IS DISTINCT FROM new.archived_at)) EXECUTE FUNCTION "public"."update_activity_on_note_change"();
-- Create trigger "user_sync_note_update"
CREATE TRIGGER "user_sync_note_update" AFTER UPDATE ON "public"."note" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_note"();
-- Create trigger "enforce_note_draft_rules_trigger"
CREATE TRIGGER "enforce_note_draft_rules_trigger" BEFORE UPDATE ON "public"."note" FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft) EXECUTE FUNCTION "public"."enforce_draft_rules"();
-- Create "sync_twist_for_note_tag" function
CREATE FUNCTION "public"."sync_twist_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_priority_twist_id uuid;
BEGIN
    -- Only consider tags on non-draft notes on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
    -- Exit early if all changes were to tags on draft notes or draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Track sync state for twists that created the affected notes
    -- Only consider tags on non-draft notes on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN priority p_child ON p_child.id = a.priority_id
                JOIN priority p_parent ON p_child.path <@ p_parent.path
                JOIN priority_twist pct ON pct.priority_id = p_parent.id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        -- Track sync for the twist that created this note
        AND nt.created_by = pct.id
    ORDER BY
        pct.id LOOP
            INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
            ON CONFLICT (priority_twist_id, entity, operation)
                DO UPDATE SET
                    last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "twist_sync_note_tag_insert"
CREATE TRIGGER "twist_sync_note_tag_insert" AFTER INSERT ON "public"."note_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note_tag"();
-- Create "sync_user_for_note_tag" function
CREATE FUNCTION "public"."sync_user_for_note_tag" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent note's activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_note_tag_insert"
CREATE TRIGGER "user_sync_note_tag_insert" AFTER INSERT ON "public"."note_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_note_tag"();
-- Create trigger "set_note_tag_updated_at"
CREATE TRIGGER "set_note_tag_updated_at" BEFORE INSERT OR UPDATE ON "public"."note_tag" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "twist_sync_note_tag_update"
CREATE TRIGGER "twist_sync_note_tag_update" AFTER UPDATE ON "public"."note_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_twist_for_note_tag"();
-- Create trigger "user_sync_note_tag_update"
CREATE TRIGGER "user_sync_note_tag_update" AFTER UPDATE ON "public"."note_tag" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_note_tag"();
-- Create "insert_priority_user" function
CREATE FUNCTION "public"."insert_priority_user" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- Only create entry for new, top-level priorities, and mark them as personal
    -- Skip global priorities (those with keys starting with @, except @plot which is user-specific)
    IF nlevel (NEW.path) = 1 AND (NEW.key IS NULL OR NEW.key = '@plot' OR NOT NEW.key LIKE '@%') THEN
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (NEW.created_by, NEW.id, TRUE);
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "priority_insert_trigger"
CREATE TRIGGER "priority_insert_trigger" AFTER INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."insert_priority_user"();
-- Create "sync_user_for_priority" function
CREATE FUNCTION "public"."sync_user_for_priority" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access via ancestors)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_priority_insert"
CREATE TRIGGER "user_sync_priority_insert" AFTER INSERT ON "public"."priority" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority"();
-- Create trigger "set_priority_created_at"
CREATE TRIGGER "set_priority_created_at" BEFORE INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "update_created_by" function
CREATE FUNCTION "public"."update_created_by" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_by = NEW.created_by;
    RETURN NEW;
END;
$$;
-- Create trigger "set_priority_created_by"
CREATE TRIGGER "set_priority_created_by" BEFORE INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."update_created_by"();
-- Create trigger "set_priority_updated_at"
CREATE TRIGGER "set_priority_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_priority_update"
CREATE TRIGGER "user_sync_priority_update" AFTER UPDATE ON "public"."priority" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority"();
-- Modify "priority_twist" table
ALTER TABLE "public"."priority_twist" ADD COLUMN "suspended_at" timestamptz NULL;
-- Create "actor" view
CREATE VIEW "public"."actor" (
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
    'priority_twist'::text AS type,
    pt.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at
   FROM public.priority_twist pt;
-- Create "priority_member" view
CREATE VIEW "public"."priority_member" (
  "contact_id",
  "priority_id",
  "created_at",
  "updated_at",
  "archived_at",
  "status",
  "invited_by",
  "personal"
) AS SELECT pc.contact_id,
    pc.priority_id,
    pc.created_at,
    GREATEST(pc.updated_at, COALESCE(pu.updated_at, pc.created_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        CASE
            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
            ELSE pu.archived_at
        END AS archived_at,
        CASE
            WHEN c.user_id IS NOT NULL AND pu.user_id IS NOT NULL THEN 'accepted'::text
            ELSE 'invited'::text
        END AS status,
    pc.invited_by,
    COALESCE(pu.personal, false) AS personal
   FROM public.priority_contact pc
     JOIN public.contact c ON c.id = pc.contact_id
     LEFT JOIN public.priority_user pu ON pu.user_id = c.user_id AND pu.priority_id = pc.priority_id
  WHERE pu.user_id IS NOT NULL OR pc.invited_by IS NOT NULL;
-- Create "sync_user_for_priority_contact" function
CREATE FUNCTION "public"."sync_user_for_priority_contact" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from priority_contact changes
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
    ORDER BY
        upe.user_id LOOP
            -- Handle actor entity (priority_contact contributes to actor view)
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            -- Handle priority_member entity only for actual invitations (invited_by IS NOT NULL)
            IF EXISTS (
                SELECT
                    1
                FROM
                    new_table n2
                WHERE
                    n2.invited_by IS NOT NULL) THEN
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_member', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END IF;
END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_priority_contact_insert"
CREATE TRIGGER "user_sync_priority_contact_insert" AFTER INSERT ON "public"."priority_contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_contact"();
-- Create trigger "user_sync_priority_contact_update"
CREATE TRIGGER "user_sync_priority_contact_update" AFTER UPDATE ON "public"."priority_contact" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_contact"();
-- Create trigger "set_priority_contact_updated_at"
CREATE TRIGGER "set_priority_contact_updated_at" BEFORE UPDATE ON "public"."priority_contact" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_priority_settings_updated_at"
CREATE TRIGGER "set_priority_settings_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "sync_user_for_priority_twist" function
CREATE FUNCTION "public"."sync_user_for_priority_twist" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
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
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_twist', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_priority_twist_insert"
CREATE TRIGGER "user_sync_priority_twist_insert" AFTER INSERT ON "public"."priority_twist" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_twist"();
-- Create trigger "set_priority_twist_created_at"
CREATE TRIGGER "set_priority_twist_created_at" BEFORE INSERT ON "public"."priority_twist" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create "set_priority_twist_owner_id" function
CREATE FUNCTION "public"."set_priority_twist_owner_id" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NEW.owner_id IS NULL THEN
        RAISE EXCEPTION 'owner_id must be provided';
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "set_priority_twist_owner_id"
CREATE TRIGGER "set_priority_twist_owner_id" BEFORE INSERT ON "public"."priority_twist" FOR EACH ROW EXECUTE FUNCTION "public"."set_priority_twist_owner_id"();
-- Create trigger "set_priority_twist_updated_at"
CREATE TRIGGER "set_priority_twist_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_twist" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_priority_twist_update"
CREATE TRIGGER "user_sync_priority_twist_update" AFTER UPDATE ON "public"."priority_twist" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_twist"();
-- Create "prevent_priority_twist_immutable_changes" function
CREATE FUNCTION "public"."prevent_priority_twist_immutable_changes" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- Prevent changing twist_id
    IF OLD.twist_id IS DISTINCT FROM NEW.twist_id THEN
        RAISE EXCEPTION 'Cannot change twist_id of an existing priority_twist';
    END IF;
    -- Prevent changing owner_id
    IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION 'Cannot change owner_id of an existing priority_twist';
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "prevent_priority_twist_immutable_changes"
CREATE TRIGGER "prevent_priority_twist_immutable_changes" BEFORE UPDATE ON "public"."priority_twist" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_priority_twist_immutable_changes"();
-- Create "ensure_priority_user_contact" function
CREATE FUNCTION "public"."ensure_priority_user_contact" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT
        NEW.priority_id,
        c.id
    FROM
        contact c
    WHERE
        c.user_id = NEW.user_id
        AND c."primary" = TRUE
        AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id)
        DO NOTHING;
    RETURN NULL;
END;
$$;
-- Create trigger "ensure_priority_user_contact_trigger"
CREATE TRIGGER "ensure_priority_user_contact_trigger" AFTER INSERT ON "public"."priority_user" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_priority_user_contact"();
-- Create "sync_user_for_priority_user" function
CREATE FUNCTION "public"."sync_user_for_priority_user" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
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
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_member', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    -- Also sync priority entity so user's accessible priorities update
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_priority_user_insert"
CREATE TRIGGER "user_sync_priority_user_insert" AFTER INSERT ON "public"."priority_user" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_user"();
-- Create trigger "set_priority_user_created_at"
CREATE TRIGGER "set_priority_user_created_at" BEFORE INSERT ON "public"."priority_user" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_priority_user_updated_at"
CREATE TRIGGER "set_priority_user_updated_at" BEFORE INSERT OR UPDATE ON "public"."priority_user" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_priority_user_update"
CREATE TRIGGER "user_sync_priority_user_update" AFTER UPDATE ON "public"."priority_user" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_priority_user"();
-- Create trigger "set_publisher_created_at"
CREATE TRIGGER "set_publisher_created_at" BEFORE INSERT ON "public"."publisher" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_publisher_updated_at"
CREATE TRIGGER "set_publisher_updated_at" BEFORE INSERT OR UPDATE ON "public"."publisher" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_series_created_at"
CREATE TRIGGER "set_series_created_at" BEFORE INSERT ON "public"."series" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_series_updated_at"
CREATE TRIGGER "set_series_updated_at" BEFORE INSERT OR UPDATE ON "public"."series" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "sync_user_for_session" function
CREATE FUNCTION "public"."sync_user_for_session" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the session owner
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'session', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create trigger "user_sync_session_insert"
CREATE TRIGGER "user_sync_session_insert" AFTER INSERT ON "public"."session" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_session"();
-- Create trigger "set_session_created_at"
CREATE TRIGGER "set_session_created_at" BEFORE INSERT ON "public"."session" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_session_updated_at"
CREATE TRIGGER "set_session_updated_at" BEFORE INSERT OR UPDATE ON "public"."session" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_session_update"
CREATE TRIGGER "user_sync_session_update" AFTER UPDATE ON "public"."session" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_session"();
-- Create trigger "set_token_created_at"
CREATE TRIGGER "set_token_created_at" BEFORE INSERT ON "public"."token" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_token_updated_at"
CREATE TRIGGER "set_token_updated_at" BEFORE INSERT OR UPDATE ON "public"."token" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_twist_created_at"
CREATE TRIGGER "set_twist_created_at" BEFORE INSERT ON "public"."twist" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_twist_updated_at"
CREATE TRIGGER "set_twist_updated_at" BEFORE INSERT OR UPDATE ON "public"."twist" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_twist_admin_created_at"
CREATE TRIGGER "set_twist_admin_created_at" BEFORE INSERT ON "public"."twist_admin" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_twist_admin_updated_at"
CREATE TRIGGER "set_twist_admin_updated_at" BEFORE INSERT OR UPDATE ON "public"."twist_admin" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_usage_created_at"
CREATE TRIGGER "set_usage_created_at" BEFORE INSERT ON "public"."usage" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_usage_updated_at"
CREATE TRIGGER "set_usage_updated_at" BEFORE INSERT OR UPDATE ON "public"."usage" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "activate_invited_user" function
CREATE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_root_priority_id uuid;
    v_root_priority_path ltree;
    v_new_path ltree;
BEGIN
    -- Check if root priority already exists
    SELECT
        priority_id INTO v_root_priority_id
    FROM
        public.priority_user
    WHERE
        user_id = p_user_id
        AND personal = TRUE
    LIMIT 1;
    IF v_root_priority_id IS NOT NULL THEN
        -- Root priority already exists
        -- Ensure priority settings exist
        INSERT INTO public.priority_settings (user_id, priority_id)
            VALUES (p_user_id, v_root_priority_id)
        ON CONFLICT (user_id, priority_id)
            DO NOTHING;
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- Create root priority
    -- Generate path
    v_new_path := generate_path (NULL);
    -- Insert priority
    INSERT INTO public.priority (created_by, title, path, color)
        VALUES (p_user_id, 'Everything', v_new_path, 0)
    RETURNING
        id, path INTO v_root_priority_id, v_root_priority_path;
    -- Mark the priority_user entry as personal (root)
    -- The insert_priority_user trigger already created a priority_user entry
    UPDATE
        public.priority_user
    SET
        personal = TRUE
    WHERE
        user_id = p_user_id
        AND priority_id = v_root_priority_id;
    -- Create priority settings if they don't exist
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (p_user_id, v_root_priority_id)
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Create "accept_invitations_on_signup" function
CREATE FUNCTION "public"."accept_invitations_on_signup" () RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_contact_id uuid;
BEGIN
    -- Get the contact_id for this user (by email)
    SELECT
        id INTO v_contact_id
    FROM
        public.contact
    WHERE
        email = NEW.email
        AND archived_at IS NULL;
    IF v_contact_id IS NOT NULL THEN
        -- Create priority_user entries for pending invitations (from priority_contact)
        INSERT INTO public.priority_user (user_id, priority_id)
        SELECT
            NEW.id,
            pc.priority_id
        FROM
            public.priority_contact pc
        WHERE
            pc.contact_id = v_contact_id
            AND pc.invited_at IS NOT NULL
        ON CONFLICT
            DO NOTHING;
        -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
    END IF;
    -- Always set up the user with root priority and settings
    PERFORM
        public.activate_invited_user (NEW.id);
    RETURN NEW;
END;
$$;
-- Create trigger "accept_invitations_after_user_created"
CREATE TRIGGER "accept_invitations_after_user_created" AFTER INSERT ON "public"."user" FOR EACH ROW EXECUTE FUNCTION "public"."accept_invitations_on_signup"();
-- Create trigger "set_users_updated_at"
CREATE TRIGGER "set_users_updated_at" BEFORE INSERT OR UPDATE ON "public"."user" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_user_settings_updated_at"
CREATE TRIGGER "set_user_settings_updated_at" BEFORE INSERT OR UPDATE ON "public"."user_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "set_user_subscription_created_at"
CREATE TRIGGER "set_user_subscription_created_at" BEFORE INSERT ON "public"."user_subscription" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_user_subscription_updated_at"
CREATE TRIGGER "set_user_subscription_updated_at" BEFORE INSERT OR UPDATE ON "public"."user_subscription" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create "mentioned_in_activity" function
CREATE FUNCTION "user"."mentioned_in_activity" ("user_id" uuid, "activity_id" uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.activity_id = mentioned_in_activity.activity_id
                AND note.archived_at IS NULL
                AND mentioned_in_activity.user_id = ANY (note.mentions));
$$;
-- Create "get_activity_mentions" function
CREATE FUNCTION "public"."get_activity_mentions" ("p_activity_id" uuid) RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM
        note n,
        LATERAL unnest(n.mentions) AS mention
    WHERE
        n.activity_id = p_activity_id
        AND n.archived_at IS NULL
        AND n.mentions IS NOT NULL;
$$;
-- Create "activity_x" view
CREATE VIEW "public"."activity_x" (
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "meta",
  "source",
  "created_by_twist_id",
  "embedding",
  "pick_priority",
  "last_note_created_at",
  "last_note_source_created_at",
  "source_priority_root",
  "priority_path",
  "mentions"
) AS SELECT a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    public.get_activity_mentions(a.id) AS mentions
   FROM public.activity a
     JOIN public.priority p ON p.id = a.priority_id;
-- Create "activity" view
CREATE VIEW "user"."activity" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "assignee_id",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "type",
  "kind",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "meta",
  "source",
  "created_by_twist_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "range_at",
  "range_on",
  "unread"
) AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_created_at
                    ELSE COALESCE(a.last_note_created_at, a.created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_created_at, a.created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
        CASE
            WHEN a.done_at IS NOT NULL THEN tstzrange(a.done_at, a.done_at, '[]'::text)
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id OR a."on" IS NULL THEN
            CASE
                WHEN lower(a.at) >= GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) THEN a.at
                ELSE tstzrange(GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), '[]'::text)
            END
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN a.done_at IS NOT NULL THEN NULL::daterange
            WHEN a.assignee_id IS NOT NULL AND (( SELECT c.user_id
               FROM public.contact c
              WHERE c.id = a.assignee_id)) <> upe.user_id THEN NULL::daterange
            WHEN a.at IS NOT NULL THEN NULL::daterange
            WHEN a."on" IS NOT NULL THEN a."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_created_at
                ELSE COALESCE(a.last_note_created_at, a.created_at)
            END
            ELSE false
        END, false) AS unread
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.activity_read ar ON ar.user_id = upe.user_id AND ar.activity_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_activity(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::tstzrange AS at,
    NULL::daterange AS "on",
    NULL::interval AS duration,
    a.done_at,
    NULL::text AS recurrence_rule,
    NULL::timestamp with time zone[] AS recurrence_exdates,
    NULL::jsonb AS meta,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    false AS unread
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_activity(upe.user_id, a.id);
-- Create "actor" function
CREATE FUNCTION "public"."actor" ("user"."activity") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
-- Create "actor" function
CREATE FUNCTION "public"."actor" ("public"."note") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
-- Create "actor" function
CREATE FUNCTION "public"."actor" ("public"."activity") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
-- Create "actor" function
CREATE FUNCTION "public"."actor" ("public"."activity_x") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
-- Create "assignee" function
CREATE FUNCTION "public"."assignee" ("public"."activity") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.assignee_id
$$;
-- Create "count_not_null" function
CREATE FUNCTION "public"."count_not_null" ("val" anyelement) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT
        CASE WHEN val IS NULL THEN
            0
        ELSE
            1
        END;
$$;
-- Create "find_matching_activities_scored" function
CREATE FUNCTION "public"."find_matching_activities_scored" ("query_embedding" text, "created_by_id" uuid, "required_filters" jsonb DEFAULT '{}', "scored_fields" jsonb DEFAULT '{}', "activity_data" jsonb DEFAULT '{}', "similarity_threshold" double precision DEFAULT 0.7) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "total_score" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY WITH filtered_activities AS (
        -- First filter by required exact matches
        SELECT
            a.id,
            a.priority_id,
            a.title,
            a.type,
            a.mentions,
            a.meta,
            a.embedding
        FROM
            public.activity a
        WHERE
            a.created_by = created_by_id
            AND a.archived_at IS NULL
            -- Content similarity filter (when content is required)
            AND ((required_filters ? 'content'
                    AND a.embedding IS NOT NULL
                    AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold)
                OR NOT (required_filters ? 'content'))
            -- Type exact match (when type is required)
            AND ((required_filters ? 'type'
                    AND a.type = (activity_data ->> 'type')::int)
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
                        AND (a.meta IS NULL
                            OR a.meta ->> substring(key FROM 6) IS DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6))))
),
scored_activities AS (
    -- Calculate scores for each matching activity
    SELECT
        fa.id,
        fa.priority_id,
        fa.title,
        -- Sum up all scores
        (
            -- Content similarity score
            COALESCE(
                CASE WHEN scored_fields ? 'content'
                    AND fa.embedding IS NOT NULL THEN
                    (scored_fields ->> 'content')::float * (1 - (fa.embedding <=> query_embedding::vector))
                ELSE
                    0
                END, 0) +
            -- Type exact match score
            COALESCE(
                CASE WHEN scored_fields ? 'type' THEN
                    CASE WHEN fa.type = (activity_data ->> 'type')::int THEN
                        (scored_fields ->> 'type')::float
                    ELSE
                        0
                END
                ELSE
                    0
                END, 0) +
            -- Mentions array overlap score
            COALESCE(
                CASE WHEN scored_fields ? 'mentions'
                    AND fa.mentions IS NOT NULL
                    AND jsonb_array_length(activity_data -> 'mentions') > 0 THEN
                    (scored_fields ->> 'mentions')::float * (
                        -- Count matching elements / length of existing array
                        (
                            SELECT
                                COUNT(*)::float
                            FROM jsonb_array_elements_text(fa.mentions::jsonb) existing_mention
                            WHERE
                                existing_mention IN (
                                    SELECT
                                        jsonb_array_elements_text(activity_data -> 'mentions'))) / jsonb_array_length(fa.mentions::jsonb))
                ELSE
                    0
                END, 0) +
            -- Meta field exact match scores
            COALESCE((
                SELECT
                    COALESCE(SUM(
                            CASE WHEN fa.meta IS NOT NULL
                                AND fa.meta ->> substring(key FROM 6) IS NOT DISTINCT FROM activity_data -> 'meta' ->> substring(key FROM 6) THEN
                                (scored_fields ->> key)::float
                            ELSE
                                0
                            END), 0)
                FROM jsonb_object_keys(scored_fields) AS key
                WHERE
                    key LIKE 'meta.%'), 0)) AS total_score
FROM
    filtered_activities fa
)
SELECT
    sa.id,
    sa.priority_id,
    sa.title,
    sa.total_score
FROM
    scored_activities sa
WHERE
    sa.total_score > 0
ORDER BY
    sa.total_score DESC
LIMIT 1;
END;
$$;
-- Create "find_similar_activities" function
CREATE FUNCTION "public"."find_similar_activities" ("query_embedding" text, "created_by_id" uuid, "similarity_threshold" double precision DEFAULT 0.5, "match_limit" integer DEFAULT 1) RETURNS TABLE ("id" uuid, "priority_id" uuid, "title" text, "similarity" double precision) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id,
        a.priority_id,
        a.title,
        1 - (a.embedding <=> query_embedding::vector) AS similarity
    FROM
        public.activity a
    WHERE
        a.created_by = created_by_id
        AND a.embedding IS NOT NULL
        AND a.archived_at IS NULL
        AND (1 - (a.embedding <=> query_embedding::vector)) >= similarity_threshold
    ORDER BY
        a.embedding <=> query_embedding::vector
    LIMIT match_limit;
END;
$$;
-- Create "user_has_priority_access" function
CREATE FUNCTION "public"."user_has_priority_access" ("p_user_id" uuid, "p_priority_id" uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET "search_path" = public AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = p_user_id
                AND pu.archived_at IS NULL
                AND p.id = p_priority_id)
$$;
-- Create "get_accessible_twists" function
CREATE FUNCTION "public"."get_accessible_twists" ("p_priority_id" uuid, "p_user_id" uuid) RETURNS SETOF "public"."twist" LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT DISTINCT
        twist.*
    FROM
        twist
        JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
    WHERE
        twist.environment = 'public'
        OR (twist.environment = 'personal'
            AND twist_admin.user_id = p_user_id)
        OR user_has_priority_access (p_user_id, twist_admin.priority_id)
$$;
-- Create "get_invitation_token" function
CREATE FUNCTION "public"."get_invitation_token" ("p_contact_id" uuid, "p_new_token" text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_token text;
    v_sent_at timestamptz;
BEGIN
    -- Check if invitation already exists
    SELECT
        token,
        sent_at INTO v_token,
        v_sent_at
    FROM
        public.contact_invitation
    WHERE
        contact_id = p_contact_id;
    IF v_token IS NOT NULL THEN
        -- Return existing token and sent_at
        RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', FALSE);
    END IF;
    -- Create new invitation with provided token
    INSERT INTO public.contact_invitation (contact_id, token, sent_at)
        VALUES (p_contact_id, p_new_token, now())
    RETURNING
        token, sent_at INTO v_token, v_sent_at;
    RETURN jsonb_build_object('token', v_token, 'sent_at', v_sent_at, 'is_new', TRUE);
END;
$$;
-- Create "get_pending_user_sync" function
CREATE FUNCTION "public"."get_pending_user_sync" ("p_user_id" uuid) RETURNS TABLE ("entity" text, "last_update_at" timestamptz) LANGUAGE sql STABLE SECURITY DEFINER SET "search_path" = public AS $$
SELECT
        entity,
        last_update_at
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$$;
-- Create "get_primary_contact_id" function
CREATE FUNCTION "public"."get_primary_contact_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_contact_id uuid;
    v_user_email text;
BEGIN
    -- Check for contact marked as primary
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = true;
    IF v_contact_id IS NOT NULL THEN
        RETURN v_contact_id;
    END IF;
    -- Get user's email from public."user"
    SELECT
        LOWER(email) INTO v_user_email
    FROM
        public."user"
    WHERE
        id = p_user_id;
    -- Fall back to finding contact by matching email
    IF v_user_email IS NOT NULL THEN
        SELECT
            id INTO v_contact_id
        FROM
            contact
        WHERE
            email = v_user_email
            AND user_id = p_user_id;
        RETURN v_contact_id;
    END IF;
    -- No match found
    RETURN NULL;
END;
$$;
-- Create "get_priority_twist_owner_contact" function
CREATE FUNCTION "public"."get_priority_twist_owner_contact" ("p_priority_twist_id" uuid) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT
        public.get_primary_contact_id(pt.owner_id)
    FROM
        priority_twist pt
    WHERE
        pt.id = p_priority_twist_id;
$$;
-- Create "get_stale_twist_syncs" function
CREATE FUNCTION "public"."get_stale_twist_syncs" ("p_stale_threshold" timestamptz, "p_limit" integer DEFAULT 50) RETURNS TABLE ("priority_twist_id" uuid) LANGUAGE sql STABLE SECURITY DEFINER SET "search_path" = public AS $$
SELECT DISTINCT
        pts.priority_twist_id
    FROM
        priority_twist_sync pts
        JOIN priority_twist pt ON pt.id = pts.priority_twist_id
    WHERE
        pts.last_update_at > pts.last_sync_at -- Has pending updates
        AND pts.last_sync_at < p_stale_threshold -- Hasn't synced recently
        AND pt.archived_at IS NULL -- Skip archived twists
    ORDER BY
        pts.priority_twist_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$$;
-- Create "get_stale_user_syncs" function
CREATE FUNCTION "public"."get_stale_user_syncs" ("p_stale_threshold" timestamptz, "p_limit" integer DEFAULT 50) RETURNS TABLE ("user_id" uuid) LANGUAGE sql STABLE SECURITY DEFINER SET "search_path" = public AS $$
SELECT DISTINCT
        us.user_id
    FROM
        user_sync us
    WHERE
        us.last_update_at > us.last_sync_at -- Has pending updates
        AND us.last_sync_at < p_stale_threshold -- Hasn't synced recently
    ORDER BY
        us.user_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$$;
-- Create "get_tag_type" function
CREATE FUNCTION "public"."get_tag_type" ("tag_id" integer) RETURNS "public"."tag_type" LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id BETWEEN 100 AND 999 THEN
        RETURN 'toggle'::tag_type;
    ELSE
        RETURN 'count'::tag_type;
    END IF;
END;
$$;
-- Create "is_accessible_twist" function
CREATE FUNCTION "public"."is_accessible_twist" ("p_twist_id" bigint, "p_priority_id" uuid, "p_user_id" uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
                JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
            WHERE
                twist.id = p_twist_id
                AND (twist.environment = 'public'
                    OR (twist.environment = 'personal'
                        AND twist_admin.user_id = p_user_id)
                    OR user_has_priority_access (p_user_id, twist_admin.priority_id)))
$$;
-- Create "is_rsvp_tag" function
CREATE FUNCTION "public"."is_rsvp_tag" ("tag_id" integer) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    -- RSVP tags: Attend (1019), Skip (1020), Undecided (1021)
    RETURN tag_id IN (1019, 1020, 1021);
END;
$$;
-- Create "move_priority" function
CREATE FUNCTION "public"."move_priority" ("p_priority_id" uuid, "p_new_parent_path" public.ltree) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path INTO v_old_path
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
        -- For the priority itself, use the new path directly
        WHEN path = v_old_path THEN
            v_new_path
            -- For descendants, replace the old path prefix with the new path
        ELSE
            text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
END;
$$;
-- Create "redeem_invitation_token" function
CREATE FUNCTION "public"."redeem_invitation_token" ("p_user_id" uuid, "p_token" text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_contact_id uuid;
    v_contact_user_id uuid;
    v_redeemed_by uuid;
BEGIN
    -- Find contact_invitation with this token
    SELECT
        ci.contact_id,
        ci.redeemed_by,
        c.user_id INTO v_contact_id,
        v_redeemed_by,
        v_contact_user_id
    FROM
        public.contact_invitation ci
        JOIN public.contact c ON c.id = ci.contact_id
    WHERE
        ci.token = p_token;
    IF v_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'invalid_token');
    END IF;
    -- Check if already redeemed
    IF v_redeemed_by IS NOT NULL THEN
        IF v_redeemed_by = p_user_id THEN
            -- Same user re-clicking - return success (idempotent)
            RETURN jsonb_build_object('success', TRUE, 'already_redeemed', TRUE, 'contact_id', v_contact_id);
        ELSE
            -- Different user attempting to use redeemed token
            RETURN jsonb_build_object('success', FALSE, 'error', 'already_redeemed_by_different_user');
        END IF;
    END IF;
    -- Check if contact already linked to a DIFFERENT user
    IF v_contact_user_id IS NOT NULL AND v_contact_user_id != p_user_id THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'contact_linked_to_other_user');
    END IF;
    -- Link contact to user (if not already linked)
    UPDATE
        public.contact
    SET
        user_id = p_user_id
    WHERE
        id = v_contact_id
        AND (user_id IS NULL
            OR user_id = p_user_id);
    -- Mark invitation as redeemed instead of deleting
    UPDATE
        public.contact_invitation
    SET
        redeemed_at = now(),
        redeemed_by = p_user_id
    WHERE
        contact_id = v_contact_id;
    -- Accept any pending invitations for this contact (from priority_contact)
    INSERT INTO public.priority_user (user_id, priority_id)
    SELECT
        p_user_id,
        pc.priority_id
    FROM
        public.priority_contact pc
    WHERE
        pc.contact_id = v_contact_id
        AND pc.invited_at IS NOT NULL
    ON CONFLICT
        DO NOTHING;
    -- Note: priority_contact remains - status changes from 'invited' to 'accepted' in priority_member view
    RETURN jsonb_build_object('success', TRUE, 'already_redeemed', FALSE, 'contact_id', v_contact_id);
END;
$$;
-- Create "setup_help_feedback_priority" function
CREATE FUNCTION "public"."setup_help_feedback_priority" ("p_user_name" text DEFAULT NULL::text, "p_user_id" uuid DEFAULT NULL::uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_user_id uuid;
    v_user_email text;
    v_user_name text;
    v_global_priority_id uuid;
    v_global_priority_path ltree;
    v_user_priority_id uuid;
    v_user_priority_path ltree;
    v_plot_priority_id uuid;
    v_plot_priority_path ltree;
    v_override_path ltree;
    v_user_root_path ltree;
    v_user_root_path_part text;
BEGIN
    -- Get user ID from parameter or auth context
    v_user_id := p_user_id;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;
    -- Get user's email and name from public."user"
    SELECT
        email,
        name INTO v_user_email,
        v_user_name
    FROM
        public."user"
    WHERE
        id = v_user_id;
    -- Use provided name, or fall back to user metadata, or email
    v_user_name := COALESCE(p_user_name, v_user_name, v_user_email, 'User Feedback');
    -- Step 1: Get or create global Help & Feedback priority
    SELECT
        id,
        path INTO v_global_priority_id,
        v_global_priority_path
    FROM
        priority
    WHERE
        key = '@help-feedback'
    LIMIT 1;
    IF v_global_priority_id IS NULL THEN
        -- Create global priority
        -- The insert_priority_user trigger will not create a personal entry for priorities with keys like '@help-feedback'
        v_global_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, 'Help & Feedback', v_global_priority_path, 0, '@help-feedback')
        RETURNING
            id INTO v_global_priority_id;
    END IF;
    -- Step 2: Get user's root priority path for finding their @plot priority
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = v_user_id
        AND pu.personal = TRUE
    LIMIT 1;
    IF v_user_root_path IS NULL THEN
        RAISE EXCEPTION 'User has no root priority';
    END IF;
    -- Extract root path part for filtering
    v_user_root_path_part := split_part(v_user_root_path::text, '.', 1);
    -- Step 3: Find user's @plot priority for path override
    SELECT
        id,
        path INTO v_plot_priority_id,
        v_plot_priority_path
    FROM
        priority
    WHERE
        key = '@plot'
        AND path::text LIKE v_user_root_path_part || '%'
    LIMIT 1;
    -- Step 4: Check if user's Help & Feedback priority already exists
    SELECT
        id INTO v_user_priority_id
    FROM
        priority
    WHERE
        key = '@help-feedback-' || v_user_id::text
        AND path <@ v_global_priority_path
    LIMIT 1;
    IF v_user_priority_id IS NULL THEN
        -- Create user's child priority
        v_user_priority_path := generate_path (v_global_priority_path);
        INSERT INTO priority (created_by, title, path, color, key)
            VALUES (v_user_id, v_user_name, v_user_priority_path, 0, '@help-feedback-' || v_user_id::text)
        RETURNING
            id INTO v_user_priority_id;
        -- Create priority_user entry to give user access
        INSERT INTO priority_user (user_id, priority_id, personal)
            VALUES (v_user_id, v_user_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO NOTHING;
    END IF;
    -- Step 5: Create/update priority_settings for path and title override
    IF v_plot_priority_id IS NOT NULL THEN
        -- Generate override path under user's @plot priority
        v_override_path := generate_path (v_plot_priority_path);
        -- Upsert priority_settings
        INSERT INTO priority_settings (user_id, priority_id, path, title)
            VALUES (v_user_id, v_user_priority_id, v_override_path, 'Help & Feedback')
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = EXCLUDED.path,
                title = EXCLUDED.title,
                updated_at = now();
    END IF;
    -- Return success with created IDs
    RETURN jsonb_build_object('success', TRUE, 'global_priority_id', v_global_priority_id, 'user_priority_id', v_user_priority_id, 'has_plot_override', v_plot_priority_id IS NOT NULL);
END;
$$;
-- Create "share_priority" function
CREATE FUNCTION "public"."share_priority" ("p_user_id" uuid, "p_priority_id" uuid, "p_add_actor_ids" uuid[], "p_remove_actor_ids" uuid[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    v_priority record;
    v_root_priority_id uuid;
    v_is_under_personal boolean := FALSE;
    v_old_path ltree;
    v_new_path ltree;
    v_extracted boolean := FALSE;
    v_actor_id uuid;
    v_contact record;
    v_priority_label text;
BEGIN
    -- Validate user has access to the priority
    IF NOT public.user_has_priority_access (p_user_id, p_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Get priority details
    SELECT
        * INTO v_priority
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    IF v_priority IS NULL THEN
        RAISE EXCEPTION 'Priority not found';
    END IF;
    v_old_path := v_priority.path;
    -- Check if extraction is needed:
    -- 1. Priority is NOT at top level (nlevel > 1)
    -- 2. Top-level priority is user's personal root
    IF nlevel (v_priority.path) > 1 THEN
        -- Get the root priority ID
        SELECT
            p.id INTO v_root_priority_id
        FROM
            public.priority p
        WHERE
            p.path = subltree (v_priority.path, 0, 1);
        -- Check if root is user's personal priority
        IF v_root_priority_id IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                    WHERE
                        pu.priority_id = v_root_priority_id
                        AND pu.user_id = p_user_id
                        AND pu.personal = TRUE
                        AND pu.archived_at IS NULL) INTO v_is_under_personal;
        END IF;
    END IF;
    -- Perform extraction if needed
    IF v_is_under_personal THEN
        -- Generate new top-level path
        v_new_path := public.generate_path (NULL);
        -- Update priority and all descendants
        -- Extract the last label from the current path (the priority's own identifier)
        v_priority_label := ltree2text (subpath (v_old_path, -1));
        -- The new root path is the generated path for the priority itself
        -- For descendants, append their relative path from the old location
        UPDATE
            public.priority
        SET
            path = CASE WHEN path = v_old_path THEN
                v_new_path
            ELSE
                -- For descendants, replace the old path prefix with the new path
                text2ltree (ltree2text (v_new_path) || ltree2text (subpath (path, nlevel (v_old_path))))
            END
        WHERE
            path <@ v_old_path
            OR path = v_old_path;
        -- Create priority_settings with old path to preserve visual location
        INSERT INTO public.priority_settings (user_id, priority_id, path)
            VALUES (p_user_id, p_priority_id, v_old_path)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = EXCLUDED.path;
        -- Create priority_user for current user (non-personal) for the extracted priority
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (p_user_id, p_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                archived_at = NULL;
        v_extracted := TRUE;
    END IF;
    -- Process additions
    IF p_add_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_add_actor_ids LOOP
            -- Get contact info to check if user_id is set
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id
                AND archived_at IS NULL;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Create priority_contact for all contacts (both users and non-users)
            INSERT INTO public.priority_contact (priority_id, contact_id, invited_by, invited_at)
                VALUES (p_priority_id, v_actor_id, p_user_id, now())
            ON CONFLICT (priority_id, contact_id)
                DO UPDATE SET
                    invited_at = now(),
                    invited_by = COALESCE(priority_contact.invited_by, EXCLUDED.invited_by);
            -- Reset invitation sent_at if this is a re-invitation after full removal
            -- Only reset if the contact has no other active priority invitations
            WITH other_invitations AS (
                SELECT COUNT(*) as count
                FROM public.priority_contact
                WHERE contact_id = v_actor_id
                  AND invited_at IS NOT NULL
                  AND priority_id != p_priority_id
            )
            UPDATE public.contact_invitation
            SET sent_at = now()
            WHERE contact_id = v_actor_id
              AND (SELECT count FROM other_invitations) = 0;
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - also create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal)
                    VALUES (v_contact.user_id, p_priority_id, FALSE)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
            END IF;
        END LOOP;
    END IF;
    -- Process removals
    IF p_remove_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_remove_actor_ids LOOP
            -- Get contact info
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Cancel invitation for priority_contact (set invited_at to NULL)
            UPDATE
                public.priority_contact
            SET
                invited_at = NULL
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND invited_at IS NOT NULL;
            IF v_contact.user_id IS NOT NULL THEN
                -- Archive priority_user for users
                UPDATE
                    public.priority_user
                SET
                    archived_at = now()
                WHERE
                    user_id = v_contact.user_id
                    AND priority_id = p_priority_id
                    AND archived_at IS NULL;
            END IF;
        END LOOP;
    END IF;
    -- Return result
    RETURN jsonb_build_object('id', p_priority_id, 'extracted', v_extracted, 'oldPath', CASE WHEN v_extracted THEN
            ltree2text (v_old_path)
        ELSE
            NULL
        END, 'newPath', CASE WHEN v_extracted THEN
            ltree2text (v_new_path)
        ELSE
            ltree2text (v_old_path)
        END);
END;
$$;
-- Create "sync_user_on_connect" function
CREATE FUNCTION "public"."sync_user_on_connect" ("p_user_id" uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    -- Update all user_sync rows for this user
    -- Set last_sync_at to match last_update_at since client has full data
    UPDATE
        user_sync
    SET
        last_sync_at = last_update_at
    WHERE
        user_id = p_user_id;
END;
$$;
-- Create "tstzrange_to_daterange" function
CREATE FUNCTION "public"."tstzrange_to_daterange" ("p_range" tstzrange, "p_timezone" text DEFAULT 'UTC') RETURNS daterange LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN daterange((lower(p_range) AT TIME ZONE p_timezone)::date, (upper(p_range) AT TIME ZONE p_timezone)::date,
    -- preserve inclusive/exclusive bounds of original p_range
    CASE WHEN lower_inc(p_range)
        AND upper_inc(p_range) THEN
        '[]'
    WHEN lower_inc(p_range) THEN
        '[)'
    WHEN upper_inc(p_range) THEN
        '(]'
    ELSE
        '()'
    END)::daterange;
END;
$$;
-- Create "update_invitation_sent_at" function
CREATE FUNCTION "public"."update_invitation_sent_at" ("p_contact_id" uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
BEGIN
    UPDATE
        public.contact_invitation
    SET
        sent_at = now()
    WHERE
        contact_id = p_contact_id;
END;
$$;
-- Create "updated_by_uuid" function
CREATE FUNCTION "public"."updated_by_uuid" ("id" uuid) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
SELECT
        -1 * (CASE WHEN ('x' ||
        RIGHT (REPLACE(id::text, '-', ''),
            16))::bit(64)::bigint < 0 THEN
            (('x' ||
                RIGHT (REPLACE(id::text, '-', ''),
                    16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
        ELSE
            ('x' ||
            RIGHT (REPLACE(id::text, '-', ''),
                16))::bit(64)::bigint::numeric % 2147483647
        END)
$$;
-- Create "upsert_contacts" function
CREATE FUNCTION "public"."upsert_contacts" ("_contacts" "public"."contact_upsert"[]) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO contact (user_id, email, name, avatar_url) (
        SELECT
            a.user_id,
            vals.email,
            min(vals.name),
            min(vals.avatar_url)
        FROM
            unnest(_contacts) AS vals (calendar_id,
                email,
                name,
                avatar_url)
            JOIN calendar c ON vals.calendar_id = c.id
            JOIN account a ON c.account_id = a.id
        GROUP BY
            a.user_id,
            vals.email)
ON CONFLICT (user_id,
    email)
    DO UPDATE SET
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url);
END;
$$;
-- Create "upsert_contacts" function
CREATE FUNCTION "public"."upsert_contacts" ("contacts" jsonb) RETURNS TABLE ("id" uuid, "email" text, "name" text, "user_id" uuid) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY INSERT INTO contact (email, name, avatar_url)
    SELECT
        (c ->> 'email')::text,
        (c ->> 'name')::text,
        (c ->> 'avatar_url')::text
    FROM
        jsonb_array_elements(contacts) AS c
ON CONFLICT ON CONSTRAINT contact_email_unique
    DO UPDATE SET
        name = COALESCE(EXCLUDED.name, contact.name),
        avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
END;
$$;
-- Create "upsert_user_contact" function
CREATE FUNCTION "public"."upsert_user_contact" ("user_id" uuid, "user_email" text, "user_name" text, "avatar_url" text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public AS $$
DECLARE
    _contact_id uuid;
    _existing_user_id uuid;
BEGIN
    -- Check if this email is already linked to a different user
    SELECT c.user_id INTO _existing_user_id
    FROM public.contact c
    WHERE c.email = user_email;

    IF _existing_user_id IS NOT NULL
       AND upsert_user_contact.user_id IS NOT NULL
       AND _existing_user_id IS DISTINCT FROM upsert_user_contact.user_id THEN
        RAISE EXCEPTION 'email_already_linked: This email is already associated with another account'
            USING ERRCODE = 'unique_violation';
    END IF;

    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id)
        VALUES (user_email, user_name, avatar_url, user_id)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    -- Ensure user has a primary contact
    IF NOT EXISTS (
        SELECT 1 FROM public.contact c
        WHERE c.user_id = upsert_user_contact.user_id AND c."primary" = true
    ) THEN
        UPDATE public.contact SET "primary" = true WHERE id = _contact_id;
    END IF;
    RETURN _contact_id;
END;
$$;
-- Create "week_from_date" function
CREATE FUNCTION "public"."week_from_date" ("d" date) RETURNS daterange LANGUAGE sql STABLE AS $$
SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$$;
-- Create "assert_priority_access" function
CREATE FUNCTION "user"."assert_priority_access" ("user_id" uuid, "priority_id" uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
BEGIN
    IF priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = assert_priority_access.user_id
            AND pu.archived_at IS NULL
            AND p.id = assert_priority_access.priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
END;
$$;
-- Create "delete_activity_read" function
CREATE FUNCTION "user"."delete_activity_read" ("user_id" uuid, "p_activity_id" uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(delete_activity_read.user_id, v_priority_id);

    DELETE FROM activity_read
    WHERE
        activity_read.user_id = delete_activity_read.user_id
        AND activity_read.activity_id = p_activity_id;
END;
$$;
-- Create "priority_unread" view
CREATE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(GREATEST(COALESCE(ar.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
            ELSE COALESCE(a.last_note_created_at, a.created_at)
        END)) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.activity a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at)
     LEFT JOIN public.activity_read ar ON ar.user_id = upe.user_id AND ar.activity_id = a.id
  GROUP BY upe.user_id, upe.priority_id;
-- Create "priority" view
CREATE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread"
) AS SELECT pu.user_id,
    p.id,
    p.created_at,
    GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = true AND p.id = root.id AS root,
    user_root.path OPERATOR(public.@>) p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
        CASE
            WHEN inherited_settings.path IS NOT NULL THEN inherited_settings.path
            WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
            WHEN parent_inherited_settings.path IS NOT NULL THEN parent_inherited_settings.path OPERATOR(public.||) public.subpath(p.path, public.nlevel(p.path) - 1, 1)::text::public.ltree
            ELSE user_root.path OPERATOR(public.||) p.path
        END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    COALESCE(upu.unread, false) AS unread
   FROM public.priority_user pu
     JOIN public.priority root ON pu.priority_id = root.id
     JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
     JOIN public.priority user_root ON pu_root.priority_id = user_root.id
     JOIN public.priority p ON root.path OPERATOR(public.@>) p.path
     LEFT JOIN public.priority parent_p ON public.nlevel(p.path) > 1 AND parent_p.path OPERATOR(public.=) public.subpath(p.path, 0, public.nlevel(p.path) - 1)
     LEFT JOIN public.priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id AND parent_p.id = parent_inherited_settings.priority_id
     LEFT JOIN public.priority_settings settings ON settings.user_id = pu.user_id AND p.id = settings.priority_id
     LEFT JOIN public.priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id AND p.id = inherited_settings.priority_id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
  WHERE pu.archived_at IS NULL;
-- Create "handle_priority_upsert" function
CREATE FUNCTION "user"."handle_priority_upsert" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_id uuid;
    _parent_actual_path ltree;
    _actual_path ltree;
    -- Variables for move detection
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _aliased_root_visual_path ltree;
    _aliased_root_actual_path ltree;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
    -- For storing OLD path when OLD.global_path is NULL
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = NEW.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = NEW.id) INTO _priority_exists;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since NEW.global_path is NULL (computed column)
    -- Also get OLD path if not available (happens with INSERT ... ON CONFLICT)
    IF _priority_exists THEN
        -- Get the old actual path from the database if OLD.global_path is NULL
        -- This happens when using INSERT ... ON CONFLICT (upsert)
        _old_actual_path := OLD.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = NEW.id;
        END IF;
        IF nlevel (NEW.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
            _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                id,
                global_path INTO _parent_id,
                _parent_actual_path
            FROM
                "user".priority
            WHERE
                user_id = NEW.user_id
                AND path = _parent_visual_path
            LIMIT 1;
            IF _parent_actual_path IS NULL THEN
                RAISE EXCEPTION 'Parent priority not found'
                    USING HINT = 'parent_visual_path=' || _parent_visual_path::text;
                END IF;
                -- Compute what the new actual path would be
                _actual_path := _parent_actual_path || _label::ltree;
            ELSE
                -- Root level priority (nlevel = 1)
                _actual_path := NEW.path;
            END IF;
        END IF;
        -- Detect if this is a move (actual path changed on existing priority)
        -- Use computed actual path instead of NEW.global_path (which is NULL)
        _is_move := (_priority_exists
            AND _actual_path IS NOT NULL
            AND _old_actual_path IS DISTINCT FROM _actual_path);
        IF _is_move THEN
            -- This is a move operation
            -- Block moving root priorities
            IF NEW.root THEN
                RAISE EXCEPTION 'Cannot move root priority'
                    USING HINT = 'Root priorities define access boundaries and cannot be moved';
                END IF;
                -- Get user's personal root path (actual path)
                SELECT
                    p.path INTO _user_personal_root_path
                FROM
                    priority_user pu
                    JOIN priority p ON pu.priority_id = p.id
                WHERE
                    pu.user_id = NEW.user_id
                    AND pu.personal = TRUE
                    AND pu.archived_at IS NULL
                LIMIT 1;
                -- Determine if old and new locations are under personal root using global_path
                _old_is_personal := (_user_personal_root_path @> _old_actual_path);
                -- Determine if new location is under personal root using computed actual path
                -- (actual path was already computed before move detection)
                _new_is_personal := (_user_personal_root_path @> _actual_path);
                -- Prevent circular reference
                IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
                    RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                        USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
                    END IF;
                    -- Check if move is within an aliased tree
                    -- Find the deepest ancestor with priority_settings that creates an alias
                    _within_aliased_tree := FALSE;
                    _aliased_root_id := NULL;
                    IF NOT _old_is_personal AND _new_is_personal THEN
                        -- Look for aliased ancestor by checking priority_settings
                        -- Find deepest ancestor where both old and new global paths are under the aliased root's actual path
                        SELECT
                            ps.priority_id,
                            ps.path,
                            p.path INTO _aliased_root_id,
                            _aliased_root_visual_path,
                            _aliased_root_actual_path
                        FROM
                            priority_settings ps
                            JOIN priority p ON ps.priority_id = p.id
                        WHERE
                            ps.user_id = NEW.user_id
                            AND ps.path IS NOT NULL
                            AND NEW.path <@ ps.path
                            -- New visual path is under this aliased path
                            AND OLD.path <@ ps.path
                            -- Old visual path is also under this aliased path
                            AND ps.path != p.path
                            -- Visual path differs from actual (indicates alias)
                            AND _old_actual_path <@ p.path
                            -- Old actual path is under the aliased root's actual path
                            AND _actual_path <@ p.path
                            -- New actual path is also under the aliased root's actual path
                        ORDER BY
                            nlevel (ps.path) DESC
                            -- Deepest first
                        LIMIT 1;
                        IF _aliased_root_id IS NOT NULL THEN
                            _within_aliased_tree := TRUE;
                        END IF;
                    END IF;
                    -- Determine move type and execute appropriate action
                    IF (_old_is_personal AND _new_is_personal) OR (NOT _old_is_personal AND NOT _new_is_personal) THEN
                        -- Type 1: Actual move (within personal tree or within/between shared trees)
                        PERFORM
                            move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal
                            AND _within_aliased_tree THEN
                            -- Type 3: Actual move within aliased tree
                            -- Both old and new are under the same aliased root
                            -- This is a real organizational change within the shared tree
                            PERFORM
                                move_priority (NEW.id, _parent_actual_path);
                        _actual_path := NULL;
                        -- Path updated by move_priority, don't update priority_settings.path
                    ELSIF NOT _old_is_personal
                            AND _new_is_personal THEN
                            -- Type 2: Visual move (aliasing shared priority under personal root)
                            -- Set priority_settings.path to create visual alias
                            -- Actual path remains unchanged
                            -- This happens in the priority_settings update section below
                            _actual_path := NULL;
                        _is_visual_move := TRUE;
                        -- Don't change actual path, but DO update priority_settings.path with NEW.path
                    ELSIF _old_is_personal
                            AND NOT _new_is_personal THEN
                            -- Moving personal priority into shared tree - block this
                            RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                            USING HINT = 'Use Share dialog to share a personal priority';
                        END IF;
                    END IF;
                    -- Translate visual path to actual path for new sub-priorities
                    -- For root priorities or existing priorities, use path as-is
                    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (NEW.path) > 1 THEN
                        -- Extract parent path and label from visual path
                        _parent_visual_path := subpath (NEW.path, 0, nlevel (NEW.path) - 1);
                        _label := text(subpath (NEW.path, nlevel (NEW.path) - 1, 1));
                        -- Look up parent's actual path via user.priority view (which has global_path)
                        SELECT
                            global_path INTO _parent_actual_path
                        FROM
                            "user".priority
                        WHERE
                            user_id = NEW.user_id
                            AND path = _parent_visual_path
                        LIMIT 1;
                        IF _parent_actual_path IS NOT NULL THEN
                            -- Compute actual path for new priority
                            _actual_path := _parent_actual_path || _label::ltree;
                        ELSE
                            -- Fallback: parent not found, use path as-is (shouldn't happen)
                            _actual_path := NEW.path;
                        END IF;
                    ELSIF _is_move IS NOT TRUE THEN
                        -- Use provided path as-is (root priority or existing non-move update)
                        _actual_path := NEW.path;
                    END IF;
                    -- Get the priority's default color for initializing new priority_settings
                    SELECT
                        color INTO _priority_default_color
                    FROM
                        priority
                    WHERE
                        id = NEW.id;
                    -- Update priority table fields (title, archived_at, updated_by, color)
                    -- Note: For moves, path was already updated by move_priority()
                    -- We always update for new priorities, moves, or when any fields are provided
                    IF TRUE THEN
                        -- Only insert/update if path was computed (for new priorities)
                        -- For moves, path was already updated by move_priority()
                        IF _actual_path IS NOT NULL THEN
                            INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
                                VALUES (NEW.id, NEW.archived_at, NEW.title, CASE WHEN _is_creator THEN
                                        NEW.color
                                    ELSE
                                        NULL
                                    END, _actual_path, NEW.created_by, NEW.updated_by)
                            ON CONFLICT (id)
                                DO UPDATE SET
                                    archived_at = NEW.archived_at,
                                    title = NEW.title,
                                    color = CASE WHEN _is_creator THEN
                                        NEW.color
                                    ELSE
                                        priority.color
                                    END,
                                    updated_by = NEW.updated_by
                                RETURNING
                                    id INTO _priority_id;
                        ELSE
                            -- For moves, just update non-path fields
                            UPDATE
                                priority
                            SET
                                archived_at = NEW.archived_at,
                                title = NEW.title,
                                color = CASE WHEN _is_creator THEN
                                    NEW.color
                                ELSE
                                    priority.color
                                END,
                                updated_by = NEW.updated_by
                            WHERE
                                id = NEW.id
                            RETURNING
                                id INTO _priority_id;
                        END IF;
                    END IF;
                    -- Update priority_settings for user-specific inherited fields
                    -- Only update when:
                    -- 1. This is a visual move (Type 2) - always update path
                    -- 2. Explicit settings are provided AND this is not a non-visual move
                    IF _is_visual_move THEN
                        -- Visual move: create/update path alias
                        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                            VALUES (NEW.user_id, _priority_id, NEW.path, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                        ON CONFLICT (user_id, priority_id)
                            DO UPDATE SET
                                path = NEW.path,
                                top_order = NEW.top_order,
                                "order" = NEW.order,
                                pomodoro = NEW.pomodoro,
                                color = NEW.color;
                    ELSIF NOT _is_move
                            AND (NEW."top_order" IS NOT NULL
                                OR NEW."order" IS NOT NULL
                                OR NEW."pomodoro" IS NOT NULL
                                OR NEW."color" IS NOT NULL) THEN
                            -- Non-move update with explicit settings
                            INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
                                VALUES (NEW.user_id, _priority_id, NULL, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
                            ON CONFLICT (user_id, priority_id)
                                DO UPDATE SET
                                    top_order = NEW.top_order,
                                    "order" = NEW.order,
                                    pomodoro = NEW.pomodoro,
                                    color = NEW.color;
                    END IF;
                    RETURN NEW;
END;
$$;
-- Create "user_contact_id" function
CREATE FUNCTION "user"."user_contact_id" ("p_user_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT c.id FROM contact c WHERE c.user_id = p_user_id LIMIT 1; $$;
-- Create "update_activity_tags" function
CREATE FUNCTION "user"."update_activity_tags" ("user_id" uuid, "p_activity_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb, "p_occurrence" text DEFAULT NULL::text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    v_priority_id uuid;
BEGIN
    -- Validate that activity_id is provided
    IF p_activity_id IS NULL THEN
        RAISE EXCEPTION 'p_activity_id must be provided';
    END IF;
    -- Validate access to the activity's priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        activity a
    WHERE
        a.id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this activity';
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
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - these tags are calculated from activity state', tag_id_int;
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
                -- RSVP tags (Attend/Skip/Undecided) are mutually exclusive
                -- If adding an RSVP tag, remove the other two for this actor
                IF is_rsvp_tag (tag_id_int) THEN
                    UPDATE
                        activity_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND actor_id = p_actor_id
                        AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                        AND tag_id IN (1019, 1020, 1021) -- All RSVP tags
                        AND tag_id != tag_id_int -- Except the one being added
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_at, archived_at, updated_by)
                    VALUES (p_actor_id, p_activity_id, p_occurrence, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
                -- Ensure priority_contact exists if actor is a contact
                -- This allows contacts to be visible via RLS when tagged on activities
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
                    activity a
                WHERE
                    a.id = p_activity_id
                ON CONFLICT (priority_id,
                    contact_id)
                    DO NOTHING;
            END IF;
        ELSE
            -- Removing a tag - use update to soft delete existing records
            IF current_tag_type = 'toggle' THEN
                -- For toggle tags, remove all users' tags
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            ELSE
                -- For count/compute tags, only remove current actor's tag
                UPDATE
                    activity_tag
                SET
                    archived_at = now(),
                    updated_by = p_client_id
                WHERE
                    activity_id = p_activity_id
                    AND tag_id = tag_id_int
                    AND actor_id = p_actor_id
                    AND (occurrence IS NOT DISTINCT FROM p_occurrence)
                    AND archived_at IS NULL;
            END IF;
        END IF;
END LOOP;
END;
$$;
-- Create "update_note_tags" function
CREATE FUNCTION "user"."update_note_tags" ("user_id" uuid, "p_note_id" uuid, "p_actor_id" uuid, "p_client_id" integer, "p_tag_updates" jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
    target_actor_id uuid;
    v_priority_id uuid;
BEGIN
    -- Validate that note_id is provided
    IF p_note_id IS NULL THEN
        RAISE EXCEPTION 'p_note_id must be provided';
    END IF;
    -- Validate access to the note's activity priority
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        note n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Note not found';
    END IF;
    IF NOT "user".has_priority_access (user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this note';
    END IF;
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Parse key: "tagId" or "tagId:actorId"
            IF position(':' in tag_record.key) > 0 THEN
                tag_id_int := split_part(tag_record.key, ':', 1)::integer;
                target_actor_id := split_part(tag_record.key, ':', 2)::uuid;
            ELSE
                tag_id_int := tag_record.key::integer;
                target_actor_id := p_actor_id;
            END IF;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            -- Validate computed tags for notes
            -- Notes can have 'now' (1), 'done' (3), and 'someday' (7) tags for per-user assignment/completion
            -- But not 'later' (2), 'archived' (4), 'attachment' (5), 'link' (6) - those are computed
            IF current_tag_type = 'compute' AND tag_id_int NOT IN (1, 3, 7) THEN
                RAISE EXCEPTION 'Cannot add computed tag (tag_id: %) - this tag is calculated from note state', tag_id_int;
            END IF;
            -- Validate cross-user targeting: only allow for compute tags 1, 3, 7 (now, done, someday)
            IF target_actor_id != p_actor_id AND (current_tag_type != 'compute' OR tag_id_int NOT IN (1, 3, 7)) THEN
                RAISE EXCEPTION 'Cannot modify this tag for other users (tag_id: %)', tag_id_int;
            END IF;
            IF is_adding THEN
                -- When adding 'done' tag (3), automatically remove 'now' tag (1) for this actor
                -- This is how individual completion works for multi-assignee notes
                IF tag_id_int = 3 THEN
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = 1
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO note_tag (actor_id, note_id, tag_id, updated_at, archived_at, updated_by)
                    VALUES (target_actor_id, p_note_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (actor_id, note_id, tag_id)
                    DO UPDATE SET
                        archived_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND archived_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove target actor's tag
                    UPDATE
                        note_tag
                    SET
                        archived_at = now(),
                        updated_by = p_client_id
                    WHERE
                        note_id = p_note_id
                        AND tag_id = tag_id_int
                        AND actor_id = target_actor_id
                        AND archived_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$$;
-- Create "upsert_activity" function
CREATE FUNCTION "user"."upsert_activity" ("user_id" uuid, "p_activity" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."activity" LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_result activity;
    v_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_type activity_type;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_created_by_twist_id bigint;
    v_assignee_id uuid;
    v_author_id uuid;
    -- Array handling
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_activity ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_source := p_activity ->> 'source';
    v_type := COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type, 'note'::activity_type);
    v_priority_id := COALESCE((p_activity ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_activity ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE((p_activity ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);
    END IF;
    -- DERIVE source_priority_root from priority_id when source exists but root not provided
    IF p_activity ? 'source_priority_root' AND (p_activity ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_activity ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL
            AND v_priority_id IS NOT NULL THEN
            SELECT
                subpath (p.path, 0, 1) INTO v_source_priority_root
            FROM
                priority p
            WHERE
                p.id = v_priority_id;
    END IF;
    -- Resolve id from source if not provided (for twist-created activities)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            a.id INTO v_id
        FROM
            activity a
        WHERE
            a.source = v_source
            AND a.source_priority_root = v_source_priority_root;
    END IF;
    -- Generate id if still not resolved
    IF v_id IS NULL THEN
        v_id := gen_random_uuid_v7 ();
    END IF;
    -- Resolve priority_id from existing activity if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            activity
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
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
            pu.user_id = upsert_activity.user_id
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
                AND pt.owner_id = upsert_activity.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- DERIVE created_by_twist_id from created_by (priority_twist_id)
    IF p_activity ? 'created_by_twist_id' AND (p_activity ->> 'created_by_twist_id') IS NOT NULL THEN
        v_created_by_twist_id := (p_activity ->> 'created_by_twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_created_by_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;
    -- DERIVE default assignee for actions when assignee_id key is absent from both p_activity and p_defaults
    -- If key exists in p_activity (even with null value), use that value
    -- If key exists in p_defaults (even with null value), use that value
    -- If key is absent from both AND type is action, derive from priority_twist owner
    IF p_activity ? 'assignee_id' THEN
        v_assignee_id := (p_activity ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSIF v_type = 'action'
            AND v_created_by IS NOT NULL THEN
            v_assignee_id := get_priority_twist_owner_contact (v_created_by);
    ELSE
        v_assignee_id := NULL;
    END IF;
    -- Handle recurrence_exdates array conversion from JSONB (p_activity takes precedence over p_defaults)
    IF p_activity ? 'recurrence_exdates' AND jsonb_typeof(p_activity -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Handle add/remove exdates
    IF p_activity ? 'recurrence_exdates_add' AND jsonb_typeof(p_activity -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_activity ? 'recurrence_exdates_remove' AND jsonb_typeof(p_activity -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;
    -- Check if existing activity is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (activity.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = activity.priority_id
                    AND upe.user_id = upsert_activity.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        activity
    WHERE
        id = v_id;
    -- If no existing activity, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_activity
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft, "order")
        VALUES (v_id, v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_activity ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_activity ->> 'title', p_defaults ->> 'title'), COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange), COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval), COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'), v_recurrence_exdates, COALESCE(p_activity -> 'meta', p_defaults -> 'meta'), v_source, COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_activity ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_activity -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE((p_activity ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first()))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_activity
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'title', p_defaults ->> 'title', activity.title)
            ELSE
                CASE WHEN p_activity ? 'title' THEN
                    p_activity ->> 'title'
                ELSE
                    activity.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview', activity.preview)
            ELSE
                CASE WHEN p_activity ? 'preview' THEN
                    p_activity ->> 'preview'
                ELSE
                    activity.preview
                END
            END,
            at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange, activity.at)
            ELSE
                CASE WHEN p_activity ? 'at' THEN
                    (p_activity ->> 'at')::tstzrange
                ELSE
                    activity.at
                END
            END,
            "on" = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange, activity."on")
            ELSE
                CASE WHEN p_activity ? 'on' THEN
                    (p_activity ->> 'on')::daterange
                ELSE
                    activity."on"
                END
            END,
            duration = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval, activity.duration)
            ELSE
                CASE WHEN p_activity ? 'duration' THEN
                    (p_activity ->> 'duration')::interval
                ELSE
                    activity.duration
                END
            END,
            done_at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz, activity.done_at)
            ELSE
                CASE WHEN p_activity ? 'done_at' THEN
                    (p_activity ->> 'done_at')::timestamptz
                ELSE
                    activity.done_at
                END
            END,
            recurrence_rule = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule', activity.recurrence_rule)
            ELSE
                CASE WHEN p_activity ? 'recurrence_rule' THEN
                    p_activity ->> 'recurrence_rule'
                ELSE
                    activity.recurrence_rule
                END
            END,
            recurrence_exdates = CASE WHEN v_is_archived THEN
                -- v_recurrence_exdates already has p_activity fallback to p_defaults
                COALESCE(v_recurrence_exdates, activity.recurrence_exdates)
            WHEN p_activity ? 'recurrence_exdates' THEN
                -- Full replace
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                -- Incremental add/remove
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(activity.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                activity.recurrence_exdates
            END,
            meta = CASE WHEN v_is_archived THEN
                COALESCE(p_activity -> 'meta', p_defaults -> 'meta', activity.meta)
            ELSE
                CASE WHEN p_activity ? 'meta' THEN
                    p_activity -> 'meta'
                ELSE
                    activity.meta
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, activity.updated_by)
            ELSE
                CASE WHEN p_activity ? 'updated_by' THEN
                    (p_activity ->> 'updated_by')::integer
                ELSE
                    activity.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, activity.sync_depth)
            ELSE
                CASE WHEN p_activity ? 'sync_depth' THEN
                    (p_activity ->> 'sync_depth')::smallint
                ELSE
                    activity.sync_depth
                END
            END,
            type = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type, activity.type)
            ELSE
                CASE WHEN p_activity ? 'type' THEN
                    (p_activity ->> 'type')::activity_type
                ELSE
                    activity.type
                END
            END,
            assignee_id = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_assignee_id, activity.assignee_id)
            ELSE
                CASE WHEN p_activity ? 'assignee_id' THEN
                    (p_activity ->> 'assignee_id')::uuid
                ELSE
                    COALESCE(v_assignee_id, activity.assignee_id)
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_activity ? 'priority_id' THEN
                    (p_activity ->> 'priority_id')::uuid
                ELSE
                    activity.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, activity.private)
            ELSE
                CASE WHEN p_activity ? 'private' THEN
                    (p_activity ->> 'private')::boolean
                ELSE
                    activity.private
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_activity ? 'archived_at' THEN
                    (p_activity ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    activity.archived_at
                END
            ELSE
                CASE WHEN p_activity ? 'archived_at' THEN
                    (p_activity ->> 'archived_at')::timestamptz
                ELSE
                    activity.archived_at
                END
            END,
            source = COALESCE(v_source, activity.source),
            source_priority_root = COALESCE(v_source_priority_root, activity.source_priority_root),
            created_by = v_created_by,
            created_by_twist_id = v_created_by_twist_id,
            "order" = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, activity."order")
            ELSE
                CASE WHEN p_activity ? 'order' THEN
                    (p_activity ->> 'order')::double precision
                ELSE
                    activity."order"
                END
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Create "upsert_activity_exception" function
CREATE FUNCTION "user"."upsert_activity_exception" ("user_id" uuid, "p_id" uuid, "p_activity_id" uuid, "p_occurrence" text, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_updated_by" integer DEFAULT 0, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_on" daterange DEFAULT NULL::daterange, "p_duration" interval DEFAULT NULL::interval, "p_done_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_title" text DEFAULT NULL::text, "p_preview" text DEFAULT NULL::text, "p_meta" jsonb DEFAULT NULL::jsonb) RETURNS "public"."activity_exception" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_row activity_exception;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    INSERT INTO activity_exception (id, activity_id, occurrence, archived_at, updated_by, at, "on", duration, done_at, title, preview, meta)
        VALUES (COALESCE(p_id, gen_random_uuid_v7()), p_activity_id, p_occurrence, p_archived_at, COALESCE(p_updated_by, 0), p_at, p_on, p_duration, p_done_at, p_title, p_preview, p_meta)
    ON CONFLICT (activity_id, occurrence)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            at = EXCLUDED.at,
            "on" = EXCLUDED."on",
            duration = EXCLUDED.duration,
            done_at = EXCLUDED.done_at,
            title = EXCLUDED.title,
            preview = EXCLUDED.preview,
            meta = EXCLUDED.meta,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_activity_read" function
CREATE FUNCTION "user"."upsert_activity_read" ("user_id" uuid, "p_activity_id" uuid, "p_read_at" timestamptz) RETURNS "public"."activity_read" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_row activity_read;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    INSERT INTO activity_read (user_id, activity_id, read_at)
        VALUES (user_id, p_activity_id, COALESCE(p_read_at, now()))
    ON CONFLICT (user_id, activity_id)
        DO UPDATE SET
            read_at = EXCLUDED.read_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_activity_tag" function
CREATE FUNCTION "user"."upsert_activity_tag" ("user_id" uuid, "p_actor_id" uuid, "p_activity_id" uuid, "p_tag_id" integer, "p_occurrence" text DEFAULT NULL::text, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."activity_tag" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row activity_tag;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO activity_tag (actor_id, activity_id, occurrence, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_activity_id, p_occurrence, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, activity_id, occurrence, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_note" function
CREATE FUNCTION "user"."upsert_note" ("user_id" uuid, "p_id" uuid, "p_author_id" uuid, "p_created_by" uuid, "p_updated_by" integer, "p_archived_at" timestamptz, "p_activity_id" uuid, "p_draft" boolean, "p_private" boolean, "p_content" text, "p_links" jsonb, "p_mentions" uuid[], "p_re_note_id" uuid, "p_source_created_at" timestamptz, "p_key" text) RETURNS "public"."note" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_created_by uuid;
    v_author_id uuid;
    v_row note;
BEGIN
    SELECT
        priority_id INTO v_priority_id
    FROM
        activity
    WHERE
        id = p_activity_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Activity not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

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
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_note.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (gen_random_uuid_v7(), v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (activity_id, key)
            DO UPDATE SET
                author_id = EXCLUDED.author_id,
                created_by = EXCLUDED.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    ELSE
        INSERT INTO note (id, author_id, created_by, updated_by, archived_at, activity_id, draft, private, content, links, mentions, re_note_id, source_created_at, key)
            VALUES (p_id, v_author_id, v_created_by, COALESCE(p_updated_by, 0), p_archived_at, p_activity_id, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_content, p_links, p_mentions, p_re_note_id, COALESCE(p_source_created_at, now()), p_key)
        ON CONFLICT (id)
            DO UPDATE SET
                author_id = EXCLUDED.author_id,
                created_by = EXCLUDED.created_by,
                updated_by = EXCLUDED.updated_by,
                archived_at = EXCLUDED.archived_at,
                draft = EXCLUDED.draft,
                private = EXCLUDED.private,
                content = EXCLUDED.content,
                links = EXCLUDED.links,
                mentions = EXCLUDED.mentions,
                re_note_id = EXCLUDED.re_note_id,
                source_created_at = EXCLUDED.source_created_at,
                key = EXCLUDED.key,
                updated_at = now()
        RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
END;
$$;
-- Create "upsert_note_tag" function
CREATE FUNCTION "user"."upsert_note_tag" ("user_id" uuid, "p_actor_id" uuid, "p_note_id" uuid, "p_tag_id" integer, "p_updated_by" integer DEFAULT 0, "p_archived_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."note_tag" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
    v_tag_type tag_type;
    v_row note_tag;
BEGIN
    SELECT
        a.priority_id INTO v_priority_id
    FROM
        note n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.id = p_note_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Note not found';
    END IF;
    PERFORM "user".assert_priority_access(user_id, v_priority_id);

    v_tag_type := get_tag_type(p_tag_id);
    IF v_tag_type = 'compute' THEN
        RAISE EXCEPTION 'Cannot add computed tag (tag_id: %)', p_tag_id;
    END IF;
    IF v_tag_type = 'count' AND p_actor_id != "user".user_contact_id(user_id) THEN
        RAISE EXCEPTION 'Cannot modify count tags for other users (tag_id: %)', p_tag_id;
    END IF;

    INSERT INTO note_tag (actor_id, note_id, tag_id, updated_by, archived_at)
        VALUES (p_actor_id, p_note_id, p_tag_id, COALESCE(p_updated_by, 0), p_archived_at)
    ON CONFLICT (actor_id, note_id, tag_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_priority" function
CREATE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_row "user"."priority";
BEGIN
    INSERT INTO "user"."priority"
    SELECT
        (jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', user_id))).*
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_priority_member" function
CREATE FUNCTION "user"."upsert_priority_member" ("user_id" uuid, "p_contact_id" uuid, "p_priority_id" uuid, "p_invited_by" uuid, "p_invited_at" timestamptz) RETURNS "public"."priority_member" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_row priority_member;
BEGIN
    PERFORM "user".assert_priority_access(user_id, p_priority_id);

    INSERT INTO priority_contact (priority_id, contact_id, invited_by, invited_at)
        VALUES (p_priority_id, p_contact_id, p_invited_by, p_invited_at)
    ON CONFLICT (priority_id, contact_id)
        DO UPDATE SET
            invited_by = EXCLUDED.invited_by,
            invited_at = EXCLUDED.invited_at,
            updated_at = now();

    SELECT
        * INTO v_row
    FROM
        priority_member
    WHERE
        priority_id = p_priority_id
        AND contact_id = p_contact_id;

    RETURN v_row;
END;
$$;
-- Create "upsert_priority_twist" function
CREATE FUNCTION "user"."upsert_priority_twist" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."priority_twist" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_row priority_twist;
BEGIN
    PERFORM "user".assert_priority_access(user_id, p_priority_id);
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    INSERT INTO priority_twist (id, priority_id, twist_id, owner_id, name, config, archived_at)
        VALUES (COALESCE(p_id, gen_random_uuid_v7()), p_priority_id, p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
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
-- Create "upsert_priority_user" function
CREATE FUNCTION "user"."upsert_priority_user" ("user_id" uuid, "p_priority_id" uuid, "p_archived_at" timestamptz, "p_personal" boolean) RETURNS "public"."priority_user" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_row priority_user;
BEGIN
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user
        WHERE
            user_id = upsert_priority_user.user_id
            AND priority_id = p_priority_id) THEN
        RAISE EXCEPTION 'priority_user not found';
    END IF;

    INSERT INTO priority_user (user_id, priority_id, archived_at, personal)
        VALUES (user_id, p_priority_id, p_archived_at, COALESCE(p_personal, FALSE))
    ON CONFLICT (user_id, priority_id)
        DO UPDATE SET
            archived_at = EXCLUDED.archived_at,
            personal = EXCLUDED.personal,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_session" function
CREATE FUNCTION "user"."upsert_session" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_at" tstzrange, "p_precedence" smallint, "p_pomodoro" smallint, "p_pomodoro_at" timestamptz, "p_archived_at" timestamptz, "p_updated_by" integer) RETURNS "public"."session" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
DECLARE
    v_row session;
BEGIN
    IF p_priority_id IS NOT NULL THEN
        PERFORM "user".assert_priority_access(user_id, p_priority_id);
    END IF;

    IF p_id IS NOT NULL AND EXISTS (
        SELECT
            1
        FROM
            session s
        WHERE
            s.id = p_id
            AND s.user_id <> upsert_session.user_id) THEN
        RAISE EXCEPTION 'Cannot modify another user''s session';
    END IF;

    INSERT INTO session (id, user_id, priority_id, at, precedence, pomodoro, pomodoro_at, archived_at, updated_by)
        VALUES (COALESCE(p_id, gen_random_uuid_v7()), user_id, p_priority_id, p_at, COALESCE(p_precedence, 0), p_pomodoro, p_pomodoro_at, p_archived_at, COALESCE(p_updated_by, 0))
    ON CONFLICT (id)
        DO UPDATE SET
            priority_id = EXCLUDED.priority_id,
            at = EXCLUDED.at,
            precedence = EXCLUDED.precedence,
            pomodoro = EXCLUDED.pomodoro,
            pomodoro_at = EXCLUDED.pomodoro_at,
            archived_at = EXCLUDED.archived_at,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "upsert_user_settings" function
CREATE FUNCTION "user"."upsert_user_settings" ("user_id" uuid, "p_enter_behavior" "public"."enter_behavior") RETURNS "public"."user_settings" LANGUAGE plpgsql SECURITY DEFINER SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_row user_settings;
BEGIN
    INSERT INTO user_settings (user_id, enter_behavior)
        VALUES (upsert_user_settings.user_id, p_enter_behavior)
    ON CONFLICT (user_id)
        DO UPDATE SET
            enter_behavior = EXCLUDED.enter_behavior,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "activity_tags" view
CREATE VIEW "public"."activity_tags" (
  "activity_id",
  "occurrence",
  "tags",
  "updated_at",
  "updated_by"
) AS SELECT activity_id,
    occurrence,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT at.activity_id,
            at.occurrence,
            at.tag_id,
            jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
            max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
            (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
           FROM public.activity_tag at
          GROUP BY at.activity_id, at.occurrence, at.tag_id) sq
  GROUP BY activity_id, occurrence;
-- Create "note_tags" view
CREATE VIEW "public"."note_tags" (
  "note_id",
  "tags",
  "updated_at",
  "updated_by"
) AS SELECT note_id,
    jsonb_object_agg(tag_id, actor_ids) FILTER (WHERE actor_ids IS NOT NULL AND jsonb_array_length(actor_ids) > 0) AS tags,
    max(updated_at) AS updated_at,
    (array_agg(updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
   FROM ( SELECT nt.note_id,
            nt.tag_id,
            jsonb_agg(nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
            max(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
            (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
           FROM public.note_tag nt
          GROUP BY nt.note_id, nt.tag_id) sq
  GROUP BY note_id;
-- Create "priority_child_twist" view
CREATE VIEW "public"."priority_child_twist" (
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
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
   FROM public.priority_twist pt
     JOIN public.priority_child pc ON pt.priority_id = pc.priority_id
     JOIN public.twist t ON pt.twist_id = t.id
     JOIN public.twist_admin ta ON t.twist_admin_id = ta.id
     LEFT JOIN public.publisher p ON ta.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "priority_tags" view
CREATE VIEW "public"."priority_tags" (
  "priority_id",
  "tag_id",
  "count",
  "updated_at"
) AS SELECT a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at
   FROM public.activity_tag at
     JOIN public.activity a ON at.activity_id = a.id
  WHERE at.archived_at IS NULL AND a.archived_at IS NULL
  GROUP BY a.priority_id, at.tag_id;
-- Create "priority_twist_activity_create" view
CREATE VIEW "public"."priority_twist_activity_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT pt.id AS priority_twist_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_activity_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.activity_tags at ON at.activity_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id <> a.created_by AND a.archived_at IS NULL AND pt.archived_at IS NULL AND a.created_at > pt.created_at
  ORDER BY a.created_at;
-- Create "priority_twist_activity_tag_change" view
CREATE VIEW "public"."priority_twist_activity_tag_change" (
  "priority_twist_id",
  "activity_id",
  "occurrence",
  "tag_id",
  "actor_id",
  "updated_at",
  "change_type"
) AS SELECT a.created_by AS priority_twist_id,
    at.activity_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
        CASE
            WHEN at.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.activity_tag at
     JOIN public.activity a ON a.id = at.activity_id
     JOIN public.priority_child_twist pct ON pct.priority_child_id = a.priority_id AND pct.id = a.created_by
  WHERE a.draft = false;
-- Create "priority_twist_activity_update" view
CREATE VIEW "public"."priority_twist_activity_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "assignee_id",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "type",
  "order",
  "draft",
  "private",
  "title",
  "preview",
  "at",
  "on",
  "duration",
  "done_at",
  "recurrence_rule",
  "recurrence_exdates",
  "source",
  "meta",
  "mentions",
  "author_name",
  "author_type",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_activity_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     LEFT JOIN public.actor author ON author.id = a.author_id
     LEFT JOIN public.activity_tags at ON at.activity_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND pt.id = a.created_by AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
-- Create "priority_twist_note_create" view
CREATE VIEW "public"."priority_twist_note_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "activity_id",
  "draft",
  "private",
  "content",
  "links",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "activity_title",
  "activity_created_by",
  "activity_meta",
  "activity_mentions",
  "author_name",
  "author_type",
  "tags",
  "first_mentioned_at"
) AS SELECT pt.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    public.get_activity_mentions(a.id) AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     JOIN public.note n ON n.activity_id = a.id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
     LEFT JOIN LATERAL ( SELECT min(note.created_at) AS first_mentioned_at
           FROM public.note
          WHERE note.activity_id = a.id AND (pt.id = ANY (note.mentions)) AND note.archived_at IS NULL) fm ON true
  WHERE n.draft = false AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.created_at > pt.created_at AND (a.created_by = pt.id OR fm.first_mentioned_at IS NOT NULL AND n.created_at >= fm.first_mentioned_at)
  ORDER BY n.created_at;
-- Create "priority_twist_note_update" view
CREATE VIEW "public"."priority_twist_note_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "activity_id",
  "draft",
  "private",
  "content",
  "links",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "activity_title",
  "activity_created_by",
  "activity_meta",
  "activity_mentions",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    public.get_activity_mentions(a.id) AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     JOIN public.note n ON a.id = n.activity_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
-- Create "activity_exception" view
CREATE VIEW "user"."activity_exception" (
  "user_id",
  "id",
  "activity_id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_path",
  "range_at",
  "range_on",
  "at",
  "on",
  "title",
  "preview"
) AS SELECT ua.user_id,
    ae.id,
    ae.activity_id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae."on",
    ae.title,
    ae.preview
   FROM public.activity_exception ae
     JOIN "user".activity ua ON ua.id = ae.activity_id;
-- Create "activity_tags" view
CREATE VIEW "user"."activity_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_path",
  "range_at",
  "range_on",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
   FROM public.activity_tags at
     JOIN "user".activity ua ON ua.id = at.activity_id;
-- Create "priority_actor" view
CREATE VIEW "user"."priority_actor" (
  "user_id",
  "priority_path",
  "actor_id",
  "created_at",
  "updated_at",
  "archived_at"
) AS SELECT user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
   FROM ( SELECT upe.user_id,
            upe.path AS priority_path,
            pc.contact_id AS actor_id,
            LEAST(COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST(pc.updated_at, c.updated_at) AS updated_at,
                CASE
                    WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                    ELSE c.archived_at
                END AS archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_contact pc ON pc.priority_id = upe.priority_id
             JOIN public.contact c ON c.id = pc.contact_id
        UNION ALL
         SELECT upe.user_id,
            upe.path AS priority_path,
            pt.id AS actor_id,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM "user".priority_expanded upe
             JOIN public.priority_twist pt ON pt.priority_id = upe.priority_id) actors;
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
) AS WITH upa_agg AS (
         SELECT upa.user_id,
            upa.actor_id,
            COALESCE(min(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), max(upa.archived_at)) AS updated_at,
                CASE
                    WHEN count(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN max(upa.archived_at)
                    ELSE NULL::timestamp with time zone
                END AS archived_at
           FROM "user".priority_actor upa
          GROUP BY upa.user_id, upa.actor_id
        )
 SELECT ua.user_id,
    a.id,
    a.created_at,
    GREATEST(ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c
          WHERE c.id = a.id AND c.user_id = ua.user_id)) AS self
   FROM upa_agg ua
     JOIN public.actor a ON a.id = ua.actor_id;
-- Create "note" view
CREATE VIEW "user"."note" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "activity_id",
  "draft",
  "private",
  "content",
  "links",
  "mentions",
  "re_note_id"
) AS SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions,
    n.re_note_id
   FROM public.note n
     JOIN public.activity a ON a.id = n.activity_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (n.private = false OR n.created_by = upe.user_id OR (upe.user_id = ANY (n.mentions))) AND (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_activity(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.activity_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS links,
    NULL::uuid[] AS mentions,
    n.re_note_id
   FROM public.note n
     JOIN public.activity a ON a.id = n.activity_id
     JOIN "user".priority_expanded upe ON upe.priority_id = a.priority_id
  WHERE (n.draft = false OR n.created_by = upe.user_id) AND (a.draft = false OR a.created_by = upe.user_id) AND (n.private = true AND n.created_by <> upe.user_id AND NOT (upe.user_id = ANY (COALESCE(n.mentions, '{}'::uuid[]))) OR a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_activity(upe.user_id, a.id));
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_path",
  "range_at",
  "range_on",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".activity ua ON ua.id = n.activity_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR (ua.user_id = ANY (n.mentions)));
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "priority_id",
  "twist_id",
  "twist_environment",
  "owner_id",
  "name",
  "config"
) AS SELECT upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
   FROM public.priority_twist pt
     JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
     JOIN public.twist t ON pt.twist_id = t.id;
