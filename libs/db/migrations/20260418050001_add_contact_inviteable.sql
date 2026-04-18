-- Modify "contact" table
ALTER TABLE "public"."contact" ADD COLUMN "inviteable" boolean NOT NULL DEFAULT true;
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
    pt.name,
    NULL::text AS email,
    NULL::text AS avatar_url,
    pt.archived_at,
    true AS inviteable
   FROM public.twist_instance pt;
-- Modify "actor" view
CREATE OR REPLACE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self",
  "inviteable"
) AS SELECT uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c_1
          WHERE c_1.id = a.id AND c_1.user_id = uc.user_id)) AS self,
    a.inviteable
   FROM public.user_contact uc
     JOIN public.contact c ON c.id = uc.contact_id
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NULL OR c."primary" = true
UNION ALL
 SELECT uc_primary.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    c.user_id = uc_primary.user_id AS self,
    a.inviteable
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
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable
   FROM public."user" u
     JOIN public.twist_instance pt ON pt.owner_id = u.id
     JOIN public.actor a ON a.id = pt.id;
-- Rough pattern-based backfill. The TypeScript classifier is the source of
-- truth going forward; this SQL intentionally uses looser patterns to catch
-- the bulk of existing non-inviteable contacts. Rows missed here will only
-- be reclassified on subsequent API-side email changes, or by a follow-up
-- migration with improved patterns.
UPDATE "public"."contact" SET "inviteable" = false
WHERE "email" IS NOT NULL
  AND (
    "email" ~* '^(no-?reply|do-?not-?reply|mailer-daemon|postmaster|bounces?|notifications?|alerts?|auto-confirm|automated)(-|\+|@)'
    OR "email" ~* '@([^@]*\.)?(bounces?|mailer)\.'
    OR split_part("email", '@', 1) ~* '(^|-)(noreply|no-reply|donotreply)(-|$)'
  );
