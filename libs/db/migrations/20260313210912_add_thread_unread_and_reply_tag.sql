-- Create "thread_unread" table
CREATE TABLE "public"."thread_unread" (
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NOT NULL,
  "thread_id" uuid NOT NULL,
  "status" text NOT NULL,
  "read_at" timestamptz NULL,
  "bumped_at" timestamptz NULL,
  PRIMARY KEY ("user_id", "thread_id"),
  CONSTRAINT "thread_unread_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."thread" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_unread_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "thread_unread_status_check" CHECK (status = ANY (ARRAY['interrupt'::text, 'inform-fast'::text, 'inform-slow'::text]))
);
-- Create index "idx_thread_unread_thread_id" to table: "thread_unread"
CREATE INDEX "idx_thread_unread_thread_id" ON "public"."thread_unread" ("thread_id");
-- Create index "idx_thread_unread_user_unread" to table: "thread_unread"
CREATE INDEX "idx_thread_unread_user_unread" ON "public"."thread_unread" ("user_id", "thread_id", "read_at");
-- Create trigger "set_thread_unread_updated_at"
CREATE TRIGGER "set_thread_unread_updated_at" BEFORE INSERT OR UPDATE ON "public"."thread_unread" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "update_thread_on_note_change" function
CREATE OR REPLACE FUNCTION "public"."update_thread_on_note_change" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the thread read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this thread to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        -- Update thread's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            thread
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.thread_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
-- Create "clear_thread_unread" function
CREATE FUNCTION "user"."clear_thread_unread" ("user_id" uuid, "p_thread_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_priority_id uuid;
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
    PERFORM "user".assert_priority_access(clear_thread_unread.user_id, v_priority_id);

    UPDATE thread_unread
    SET
        read_at = now(),
        updated_at = now()
    WHERE
        thread_unread.user_id = clear_thread_unread.user_id
        AND thread_unread.thread_id = p_thread_id
        AND thread_unread.read_at IS NULL;
END;
$$;
-- Create "upsert_thread_unread" function
CREATE FUNCTION "user"."upsert_thread_unread" ("user_id" uuid, "p_thread_id" uuid, "p_status" text, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_unread" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_unread;
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
    PERFORM "user".assert_priority_access(upsert_thread_unread.user_id, v_priority_id);

    INSERT INTO thread_unread (user_id, thread_id, status, read_at, bumped_at)
        VALUES (upsert_thread_unread.user_id, p_thread_id, p_status, p_read_at, p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            status = EXCLUDED.status,
            read_at = EXCLUDED.read_at,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_unread.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Data migration: Populate thread_unread from existing thread_read rows
-- For currently-unread threads (where read_at is stale or missing), create unread rows
-- For currently-read threads, create rows with read_at set to preserve last_read_at
INSERT INTO thread_unread (user_id, thread_id, status, read_at, bumped_at, updated_at)
SELECT
    tr.user_id,
    tr.thread_id,
    'inform-slow',
    tr.read_at,
    tr.bumped_at,
    tr.updated_at
FROM thread_read tr
ON CONFLICT (user_id, thread_id) DO NOTHING;
-- Modify "priority_twist_thread_read" view
CREATE OR REPLACE VIEW "public"."priority_twist_thread_read" (
  "priority_twist_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.id = a.created_by AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.thread a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL
     JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY upe.user_id, upe.priority_id;
-- Modify "thread" view
CREATE OR REPLACE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "private",
  "title",
  "preview",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "bumped_at",
  "unread",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(tu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, false) AS unread,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, tu.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.user_id IS NULL AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    COALESCE(LEAST(( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id IS NULL AND s_agg.archived_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1), ( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id = upe.user_id AND s_agg.archived_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1)), a.created_at) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    a.created_at AS activity_at,
    a.created_at AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
