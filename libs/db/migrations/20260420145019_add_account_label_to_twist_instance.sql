-- Drop "twist_instance_thread_tag_change" view
DROP VIEW "public"."twist_instance_thread_tag_change";
-- Drop "twist_instance_details" view
DROP VIEW "public"."twist_instance_details";
-- Drop "twist" view
DROP VIEW "user"."twist";
-- Modify "twist_instance" table
ALTER TABLE "public"."twist_instance" ADD COLUMN "account_label" text NULL;
-- Create "upsert_twist_instance" function
CREATE FUNCTION "user"."upsert_twist_instance" ("user_id" uuid, "p_id" uuid, "p_twist_id" bigint, "p_owner_id" uuid, "p_team_id" bigint, "p_name" text, "p_account_label" text, "p_config" jsonb, "p_archived_at" timestamptz) RETURNS "public"."twist_instance" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_row twist_instance;
BEGIN
    -- Twist instances are owned by a user and optionally billed to a team.
    -- The caller can only manage their own instances.
    IF p_owner_id IS DISTINCT FROM user_id THEN
        RAISE EXCEPTION 'owner_id must match user_id';
    END IF;

    -- If a team is specified, the caller must be a member.
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND team_user.user_id = upsert_twist_instance.user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of team %', p_team_id;
        END IF;
    END IF;

    INSERT INTO twist_instance (id, twist_id, owner_id, team_id, name, account_label, options, archived_at)
        VALUES (COALESCE(p_id, uuidv7()), p_twist_id, p_owner_id, p_team_id, p_name, p_account_label, COALESCE(p_config, '{}'::jsonb), p_archived_at)
    ON CONFLICT (id)
        DO UPDATE SET
            name = EXCLUDED.name,
            account_label = EXCLUDED.account_label,
            team_id = EXCLUDED.team_id,
            options = EXCLUDED.options,
            archived_at = EXCLUDED.archived_at,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "twist_instance_details" view
CREATE VIEW "public"."twist_instance_details" (
  "id",
  "twist_id",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "options",
  "draft",
  "created_at",
  "updated_at",
  "archived_at",
  "suspended_at",
  "version",
  "twist_environment",
  "is_source",
  "author_name",
  "author_email",
  "author_url"
) AS SELECT pt.id,
    pt.twist_id,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.options,
    pt.draft,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.suspended_at,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id
     LEFT JOIN public.publisher p ON t.publisher_id = p.id
  WHERE pt.archived_at IS NULL;
-- Create "twist" view
CREATE VIEW "user"."twist" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "twist_id",
  "twist_environment",
  "is_source",
  "multiple_instances",
  "shared",
  "key_option",
  "owner_id",
  "team_id",
  "name",
  "account_label",
  "options",
  "logo_url",
  "logo_url_dark",
  "link_types",
  "default_mention_created",
  "default_mention_mentioned",
  "user_connected",
  "is_builtin"
) AS SELECT pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, ( SELECT max(ptc2.connected_at) AS max
           FROM public.twist_instance_connection ptc2
          WHERE ptc2.twist_instance_id = pt.id AND ptc2.user_id = pt.owner_id)) AS updated_at,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.team_id,
    pt.name,
    pt.account_label,
    pt.options,
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
        END AS user_connected,
    t.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f'::uuid AS is_builtin
   FROM public.twist_instance pt
     JOIN public.twist t ON pt.twist_id = t.id;
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
     JOIN public.twist_instance_details tid ON tid.id = a.created_by
  WHERE a.draft = false;
-- Modify "actor" view
CREATE OR REPLACE VIEW "public"."actor" (
  "id",
  "created_at",
  "updated_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "archived_at",
  "inviteable"
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
    c.archived_at,
    c.inviteable
   FROM public.contact c
UNION ALL
 SELECT pt.id,
    pt.created_at,
    pt.updated_at,
    'twist_instance'::text AS type,
        CASE
            WHEN pt.account_label IS NOT NULL AND pt.account_label <> ''::text THEN ((pt.name || ' ('::text) || pt.account_label) || ')'::text
            ELSE pt.name
        END AS name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at,
    true AS inviteable
   FROM public.twist_instance pt;
-- Drop "upsert_twist_instance" function
DROP FUNCTION "user"."upsert_twist_instance" (uuid, uuid, bigint, uuid, bigint, text, jsonb, timestamptz);

-- Data migration: strip the "(account)" suffix from existing source
-- twist_instance.name values so they show just the connector name.
UPDATE twist_instance ti
SET name = t.name
FROM twist t
WHERE t.id = ti.twist_id AND t.is_source AND ti.name <> t.name;

-- Data migration: backfill account_label for existing OAuth source connections
-- from contact.email (first connected actor). Users can re-label later in EditSource.
UPDATE twist_instance ti
SET account_label = sub.email
FROM (
    SELECT DISTINCT ON (tic.twist_instance_id)
        tic.twist_instance_id,
        c.email
    FROM twist_instance_connection tic
    JOIN contact c ON c.id = tic.actor_id
    WHERE c.email IS NOT NULL
    ORDER BY tic.twist_instance_id, tic.connected_at ASC
) sub
WHERE ti.id = sub.twist_instance_id AND ti.account_label IS NULL;

-- Data migration: backfill account_label for non-OAuth connectors from
-- options._accountName (stored string there historically).
UPDATE twist_instance ti
SET account_label = ti.options ->> '_accountName'
WHERE ti.account_label IS NULL
  AND ti.options ->> '_accountName' IS NOT NULL
  AND (ti.options ->> '_accountName') <> '';
