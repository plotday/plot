-- Modify "user_contact" table
ALTER TABLE "public"."user_contact" ADD COLUMN "name" text NULL;
-- Create "upsert_user_contact_name" function
CREATE FUNCTION "public"."upsert_user_contact_name" ("p_user_id" uuid, "p_contact_id" uuid, "p_name" text) RETURNS void LANGUAGE sql AS $$
INSERT INTO public.user_contact (user_id, contact_id, linked, source, name)
        VALUES (p_user_id, p_contact_id, false, 'observed', p_name)
    ON CONFLICT (user_id, contact_id)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, user_contact.name)
        WHERE EXCLUDED.name IS NOT NULL
            AND EXCLUDED.name IS DISTINCT FROM user_contact.name
            -- Never override the name on a user's own linked identity row.
            AND user_contact.linked = false;
$$;
-- Modify "sync_user_contact_for_thread_contacts" function
CREATE OR REPLACE FUNCTION "public"."sync_user_contact_for_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- ORDER BY (tp.user_id, arr.contact_id) locks rows in a stable order
    -- across concurrent transactions. Without it, two parallel upserts of
    -- threads with overlapping contacts/recipients can lock the same
    -- (user_id, contact_id) rows in different orders and deadlock.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    SELECT tp.user_id, arr.contact_id, false, 'thread'
    FROM thread_priority tp
    CROSS JOIN unnest(NEW.contacts) AS arr(contact_id)
    WHERE tp.thread_id = NEW.id
      AND EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
      AND (
            -- Author of the thread always sees membership. NOTE:
            -- thread.created_by may be a twist_instance_id for connector
            -- threads, in which case this predicate never matches and
            -- visibility is granted (or not) by the remaining clauses.
            tp.user_id = NEW.created_by
            -- Recipient's own linked contact is on the thread.
            OR EXISTS (
                SELECT 1
                FROM user_contact uc_self
                WHERE uc_self.user_id = tp.user_id
                  AND uc_self.linked = TRUE
                  AND uc_self.archived_at IS NULL
                  AND uc_self.contact_id = ANY(NEW.contacts)
            )
            -- Recipient is an admin of one of the thread's groups.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN group_admin ga ON ga.group_id = gid AND ga.user_id = tp.user_id
            )
            -- Recipient is a member of a private or team group on the thread.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN public."group" g ON g.id = gid AND g.type IN ('private', 'team')
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc_grp
                    ON uc_grp.contact_id = gm.contact_id
                   AND uc_grp.linked = TRUE
                   AND uc_grp.archived_at IS NULL
                WHERE uc_grp.user_id = tp.user_id
            )
      )
    ORDER BY tp.user_id, arr.contact_id
    -- Only touches archived_at; never writes `name`, so a per-user name set by
    -- upsert_user_contact_name (source = 'observed') is preserved.
    ON CONFLICT (user_id, contact_id) DO UPDATE
        SET archived_at = NULL
        WHERE user_contact.archived_at IS NOT NULL
          AND user_contact.linked = false
          AND user_contact.source = 'thread';

    RETURN NEW;
END;
$$;
-- Modify "upsert_contacts" function
CREATE OR REPLACE FUNCTION "public"."upsert_contacts" ("contacts" jsonb) RETURNS TABLE ("id" uuid, "email" text, "name" text, "user_id" uuid) LANGUAGE plpgsql AS $$
BEGIN
    -- Deduplicate by email and sort so concurrent callers acquire row
    -- locks in the same order. Without this, two sessions each upserting
    -- overlapping email sets in different orders can deadlock on the
    -- ON CONFLICT DO UPDATE row locks.
    RETURN QUERY INSERT INTO contact (email, name, avatar_url)
    SELECT DISTINCT ON (email_lower)
        email_lower,
        name_val,
        avatar_val
    FROM (
        SELECT
            lower((c ->> 'email')::text) AS email_lower,
            (c ->> 'name')::text AS name_val,
            (c ->> 'avatar_url')::text AS avatar_val
        FROM
            jsonb_array_elements(contacts) AS c
        WHERE
            -- Minimum valid email shape: non-empty local, one @, non-empty
            -- domain with at least one dot. This is not full RFC 5322 — just
            -- enough to filter out obviously broken header fragments.
            (c ->> 'email') ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    ) deduped
    ORDER BY email_lower
ON CONFLICT ON CONSTRAINT contact_email_unique
    DO UPDATE SET
        -- First-touch only: keep an existing value, fill only when NULL.
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url)
    RETURNING
        contact.id,
        contact.email,
        contact.name,
        contact.user_id;
END;
$$;
-- Modify "actor" view
CREATE OR REPLACE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self",
  "inviteable",
  "primary",
  "linked_user_id",
  "external_accounts"
) AS SELECT uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN COALESCE(uc.name, a.name)
            ELSE NULL::text
        END AS name,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.email
            ELSE NULL::text
        END AS email,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.avatar_url
            ELSE NULL::text
        END AS avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c_1
          WHERE c_1.id = a.id AND c_1.user_id = uc.user_id)) AS self,
    a.inviteable,
    true AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(( SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
           FROM public.contact_external_account cea
          WHERE cea.contact_id = a.id), '[]'::json) AS external_accounts
   FROM public.user_contact uc
     JOIN public.contact c ON c.id = uc.contact_id
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NULL OR c."primary" = true
UNION ALL
 SELECT uc_primary.user_id,
    a.id,
    a.created_at,
    GREATEST(uc_primary.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc_primary.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc_primary.archived_at) AS archived_at,
    a.type,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.name
            ELSE NULL::text
        END AS name,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.email
            ELSE NULL::text
        END AS email,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.avatar_url
            ELSE NULL::text
        END AS avatar_url,
    c.user_id = uc_primary.user_id AS self,
    a.inviteable,
    false AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(( SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
           FROM public.contact_external_account cea
          WHERE cea.contact_id = a.id), '[]'::json) AS external_accounts
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
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id,
    '[]'::json AS external_accounts
   FROM public."user" u
     JOIN public.twist_instance pt ON pt.owner_id = u.id
     JOIN public.actor a ON a.id = pt.id;
-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    s.seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', COALESCE(( SELECT uc.name
                   FROM public.user_contact uc
                  WHERE uc.contact_id = sc.contact_id AND uc.user_id = tp.user_id), c.name), 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id AND l.archived_at IS NULL
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id) AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (s.link_id IS NULL OR l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id);
