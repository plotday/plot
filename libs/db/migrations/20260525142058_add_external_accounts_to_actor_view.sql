-- Create "bump_contact_updated_at_from_cea_delete" function
CREATE FUNCTION "public"."bump_contact_updated_at_from_cea_delete" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    UPDATE contact
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT contact_id FROM old_table);
    RETURN NULL;
END;
$$;
-- Create trigger "contact_external_account_bump_contact_delete"
CREATE TRIGGER "contact_external_account_bump_contact_delete" AFTER DELETE ON "public"."contact_external_account" REFERENCING OLD TABLE AS "old_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_contact_updated_at_from_cea_delete"();
-- Create "bump_contact_updated_at_from_cea" function
CREATE FUNCTION "public"."bump_contact_updated_at_from_cea" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
BEGIN
    UPDATE contact
    SET updated_at = now()
    WHERE id IN (SELECT DISTINCT contact_id FROM new_table);
    RETURN NULL;
END;
$$;
-- Create trigger "contact_external_account_bump_contact_insert"
CREATE TRIGGER "contact_external_account_bump_contact_insert" AFTER INSERT ON "public"."contact_external_account" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_contact_updated_at_from_cea"();
-- Create trigger "contact_external_account_bump_contact_update"
CREATE TRIGGER "contact_external_account_bump_contact_update" AFTER UPDATE ON "public"."contact_external_account" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_contact_updated_at_from_cea"();
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
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.name
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
    COALESCE(( SELECT json_agg(json_build_object('provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
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
    COALESCE(( SELECT json_agg(json_build_object('provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
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
