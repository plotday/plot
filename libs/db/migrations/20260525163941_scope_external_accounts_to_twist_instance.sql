-- Per-connection scoping: contact_external_account rows are now keyed on
-- (twist_instance_id, account_id) so a Plot contact reachable through
-- multiple connections (e.g. two Slack workspaces, or Gmail + Google
-- Chat sharing one Google account) gets one row per connection. Existing
-- rows have no recoverable twist_instance_id, so they're wiped — each
-- connector re-populates on its next syncMembers / syncRelationsPage /
-- message-ingest pass. DM-style pickers degrade to "no candidates" until
-- those passes complete.
DELETE FROM "public"."contact_external_account";
-- Modify "contact_external_account" table
ALTER TABLE "public"."contact_external_account" DROP CONSTRAINT "contact_external_account_pkey", ADD COLUMN "twist_instance_id" uuid NOT NULL, ADD PRIMARY KEY ("twist_instance_id", "account_id"), ADD CONSTRAINT "contact_external_account_twist_instance_id_fkey" FOREIGN KEY ("twist_instance_id") REFERENCES "public"."twist_instance" ("id") ON UPDATE NO ACTION ON DELETE CASCADE;
-- Create index "idx_cea_lookup" to table: "contact_external_account"
CREATE INDEX "idx_cea_lookup" ON "public"."contact_external_account" ("twist_instance_id", "contact_id");
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
