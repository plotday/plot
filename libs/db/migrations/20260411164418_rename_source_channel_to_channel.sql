-- Create "sync_user_for_channel" function
CREATE FUNCTION "public"."sync_user_for_channel" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
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
                VALUES (v_user_id, 'channel', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "channel" table
CREATE TABLE "public"."channel" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "twist_instance_id" uuid NOT NULL,
  "channel_id" text NOT NULL,
  "title" text NOT NULL,
  "priority_id" uuid NULL,
  "enabled" boolean NOT NULL DEFAULT false,
  "create_threads" text NOT NULL DEFAULT 'all',
  "link_types" jsonb NULL,
  "create_threads_by_type" jsonb NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "channel_twist_instance_id_channel_id_key" UNIQUE ("twist_instance_id", "channel_id"),
  CONSTRAINT "channel_priority_id_fkey" FOREIGN KEY ("priority_id") REFERENCES "public"."priority" ("id") ON UPDATE NO ACTION ON DELETE SET NULL,
  CONSTRAINT "channel_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_channel_priority_id" to table: "channel"
CREATE INDEX "idx_channel_priority_id" ON "public"."channel" ("priority_id");
-- Create index "idx_channel_twist_instance_id" to table: "channel"
CREATE INDEX "idx_channel_twist_instance_id" ON "public"."channel" ("twist_instance_id");
-- Set comment to table: "channel"
COMMENT ON TABLE "public"."channel" IS 'Maps source channels (calendars, projects, etc.) to priorities. Each row represents a channel from an external provider that can be enabled and routed to a specific priority.';
-- Set comment to column: "channel_id" on table: "channel"
COMMENT ON COLUMN "public"."channel"."channel_id" IS 'Provider-specific global ID for the channel. The same calendar/project has the same ID across users.';
-- Set comment to column: "priority_id" on table: "channel"
COMMENT ON COLUMN "public"."channel"."priority_id" IS 'The priority this channel syncs data to. NULL means the channel is known but not routed to any priority.';
-- Create trigger "user_sync_channel_insert"
CREATE TRIGGER "user_sync_channel_insert" AFTER INSERT ON "public"."channel" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_channel"();
-- Create trigger "set_channel_created_at"
CREATE TRIGGER "set_channel_created_at" BEFORE INSERT ON "public"."channel" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_channel_updated_at"
CREATE TRIGGER "set_channel_updated_at" BEFORE INSERT OR UPDATE ON "public"."channel" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Create trigger "user_sync_channel_update"
CREATE TRIGGER "user_sync_channel_update" AFTER UPDATE ON "public"."channel" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_channel"();
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
            LEFT JOIN channel sc ON sc.twist_instance_id = l.created_by
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
-- Drop "source_channel" view
DROP VIEW "user"."source_channel";
-- Create "channel" view
CREATE VIEW "user"."channel" (
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
   FROM public.channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id;
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
             JOIN public.channel sc ON sc.priority_id = upe.priority_id
             JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id AND pt.priority_id IS NULL) actors;
-- Copy all rows from source_channel into the new channel table before dropping.
-- Preserve identity values so any external references (logs, audit trails) stay valid.
INSERT INTO "public"."channel"
    (id, twist_instance_id, channel_id, title, priority_id, enabled,
     create_threads, link_types, create_threads_by_type, created_at, updated_at)
OVERRIDING SYSTEM VALUE
SELECT id, twist_instance_id, channel_id, title, priority_id, enabled,
       create_threads, link_types, create_threads_by_type, created_at, updated_at
FROM "public"."source_channel";
-- Advance the new identity sequence past the copied ids so new inserts don't collide.
SELECT setval(
    pg_get_serial_sequence('"public"."channel"', 'id'),
    COALESCE((SELECT MAX(id) FROM "public"."channel"), 0) + 1,
    false
);
-- Drop "source_channel" table
DROP TABLE "public"."source_channel";
-- Drop "sync_user_for_source_channel" function
DROP FUNCTION "public"."sync_user_for_source_channel";
