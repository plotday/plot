-- Modify "activity" table
ALTER TABLE "public"."activity" DROP CONSTRAINT "activity_action_assignee", ADD CONSTRAINT "activity_action_assignee" CHECK ((type <> 'action'::public.activity_type) OR (assignee_id IS NOT NULL) OR (at IS NULL));
-- Create "sync_user_for_activity_user_state" function
CREATE FUNCTION "public"."sync_user_for_activity_user_state" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the owning user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity_user_state', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "activity_user_state" table
CREATE TABLE "public"."activity_user_state" (
  "user_id" uuid NOT NULL,
  "activity_id" uuid NOT NULL,
  "on" daterange NOT NULL,
  "order" double precision NOT NULL DEFAULT public.order_first(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "updated_by" integer NOT NULL DEFAULT 0,
  "sync_depth" integer NULL,
  PRIMARY KEY ("user_id", "activity_id"),
  CONSTRAINT "activity_user_state_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activity" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "activity_user_state_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_activity_user_state_activity_id" to table: "activity_user_state"
CREATE INDEX "idx_activity_user_state_activity_id" ON "public"."activity_user_state" ("activity_id");
-- Create index "idx_activity_user_state_updated_at" to table: "activity_user_state"
CREATE INDEX "idx_activity_user_state_updated_at" ON "public"."activity_user_state" ("updated_at");
-- Set comment to column: "on" on table: "activity_user_state"
COMMENT ON COLUMN "public"."activity_user_state"."on" IS 'Date range when this user wants to work on this activity. Start date determines scheduling: today or past = Do Now, future = Do Later.';
-- Create trigger "user_sync_activity_user_state_insert"
CREATE TRIGGER "user_sync_activity_user_state_insert" AFTER INSERT ON "public"."activity_user_state" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_user_state"();
-- Create trigger "set_activity_user_state_updated_at"
CREATE TRIGGER "set_activity_user_state_updated_at" BEFORE INSERT OR UPDATE ON "public"."activity_user_state" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_activity_user_state_update"
CREATE TRIGGER "user_sync_activity_user_state_update" AFTER UPDATE ON "public"."activity_user_state" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_activity_user_state"();
-- Modify "upsert_activity" function
CREATE OR REPLACE FUNCTION "user"."upsert_activity" ("user_id" uuid, "p_activity" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."activity" LANGUAGE plpgsql AS $$
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
        v_id := uuidv7 ();
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
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, links, source, updated_by, sync_depth, embedding, pick_priority, private, draft, "order")
        VALUES (v_id, v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_activity ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_activity ->> 'title', p_defaults ->> 'title'), COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange), COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval), COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'), v_recurrence_exdates, COALESCE(p_activity -> 'meta', p_defaults -> 'meta'), COALESCE(p_activity -> 'links', p_defaults -> 'links'), v_source, COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_activity ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_activity -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE((p_activity ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first()))
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
            links = CASE WHEN v_is_archived THEN
                COALESCE(p_activity -> 'links', p_defaults -> 'links', activity.links)
            ELSE
                CASE WHEN p_activity ? 'links' THEN
                    p_activity -> 'links'
                ELSE
                    activity.links
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
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, activity.draft)
            ELSE
                CASE WHEN p_activity ? 'draft' THEN
                    (p_activity ->> 'draft')::boolean
                ELSE
                    activity.draft
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
    -- Handle per-user activity state (user_on, user_order)
    -- Key present with non-null value: upsert into activity_user_state
    -- Key present with null value: delete from activity_user_state (remove from Now+Next)
    -- Key absent: don't touch activity_user_state
    IF p_activity ? 'user_on' THEN
        IF (p_activity ->> 'user_on') IS NOT NULL THEN
            INSERT INTO activity_user_state (user_id, activity_id, "on", "order")
                VALUES (
                    upsert_activity.user_id,
                    v_result.id,
                    (p_activity ->> 'user_on')::daterange,
                    COALESCE((p_activity ->> 'user_order')::double precision, public.order_first())
                )
            ON CONFLICT (user_id, activity_id)
                DO UPDATE SET
                    "on" = EXCLUDED."on",
                    "order" = COALESCE(
                        CASE WHEN p_activity ? 'user_order' THEN (p_activity ->> 'user_order')::double precision END,
                        activity_user_state."order"
                    ),
                    updated_at = now();
        ELSE
            DELETE FROM activity_user_state
            WHERE activity_user_state.user_id = upsert_activity.user_id
                AND activity_user_state.activity_id = v_result.id;
        END IF;
    ELSIF p_activity ? 'user_order' AND (p_activity ->> 'user_order') IS NOT NULL THEN
        -- Order-only update (no on change) — only update if row exists
        UPDATE activity_user_state
        SET "order" = (p_activity ->> 'user_order')::double precision,
            updated_at = now()
        WHERE activity_user_state.user_id = upsert_activity.user_id
            AND activity_user_state.activity_id = v_result.id;
    END IF;
    RETURN v_result;
END;
$$;
-- Create "delete_activity_user_state" function
CREATE FUNCTION "user"."delete_activity_user_state" ("user_id" uuid, "p_activity_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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
    PERFORM "user".assert_priority_access(delete_activity_user_state.user_id, v_priority_id);

    DELETE FROM activity_user_state
    WHERE
        activity_user_state.user_id = delete_activity_user_state.user_id
        AND activity_user_state.activity_id = p_activity_id;
END;
$$;
-- Create "upsert_activity_user_state" function
CREATE FUNCTION "user"."upsert_activity_user_state" ("user_id" uuid, "p_activity_id" uuid, "p_on" daterange, "p_order" double precision) RETURNS "public"."activity_user_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row activity_user_state;
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
    PERFORM "user".assert_priority_access(upsert_activity_user_state.user_id, v_priority_id);

    INSERT INTO activity_user_state (user_id, activity_id, "on", "order")
        VALUES (upsert_activity_user_state.user_id, p_activity_id, p_on, p_order)
    ON CONFLICT (user_id, activity_id)
        DO UPDATE SET
            "on" = EXCLUDED."on",
            "order" = EXCLUDED."order",
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Modify "activity" view
CREATE OR REPLACE VIEW "user"."activity" (
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
  "links",
  "source",
  "created_by_twist_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "range_at",
  "range_on",
  "unread",
  "user_on",
  "user_order"
) AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
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
    a.links,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
        CASE
            WHEN a.done_at IS NOT NULL THEN tstzrange(a.done_at, a.done_at, '[]'::text)
            WHEN aus."on" IS NOT NULL THEN NULL::tstzrange
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
            WHEN aus."on" IS NOT NULL THEN aus."on"
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
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(a.last_note_source_created_at, a.source_created_at)
            END
            ELSE false
        END, false) AS unread,
    aus."on" AS user_on,
    aus."order" AS user_order
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.activity_read ar ON ar.user_id = upe.user_id AND ar.activity_id = a.id
     LEFT JOIN public.activity_user_state aus ON aus.user_id = upe.user_id AND aus.activity_id = a.id
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
    NULL::jsonb AS links,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    false AS unread,
    NULL::daterange AS user_on,
    NULL::double precision AS user_order
   FROM public.activity_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_activity(upe.user_id, a.id);
