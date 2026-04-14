-- Drop dependent views first so DROP COLUMN can succeed
DROP VIEW IF EXISTS "user"."channel";
DROP VIEW IF EXISTS "user"."actor";
DROP VIEW IF EXISTS "user"."priority_actor";
-- Modify "channel" table
ALTER TABLE "public"."channel" DROP COLUMN "priority_id";
-- Set comment to table: "channel"
COMMENT ON TABLE "public"."channel" IS 'Source channels (calendars, projects, etc.) a connector exposes. Each row represents a channel from an external provider that can be enabled for sync. Routing of resulting threads to priorities is per-user via match_priority_for_user.';
-- Modify "upsert_twist_instance" function
CREATE OR REPLACE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_priority_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_name" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
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

    INSERT INTO twist_instance (id, priority_id, twist_id, owner_id, name, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_priority_id, p_twist_id, p_owner_id, p_name, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            options = EXCLUDED.options,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "channel" view
CREATE VIEW "user"."channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "enabled",
  "link_types",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.enabled,
    sc.link_types,
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
         SELECT p.user_id,
            p.path AS priority_path,
            pt.id AS actor_id,
            0 AS depth,
            pt.created_at,
            pt.updated_at,
            pt.archived_at
           FROM public.priority p
             JOIN public.twist_instance pt ON pt.owner_id = p.user_id AND pt.priority_id IS NULL
          WHERE p.archived_at IS NULL) actors;
