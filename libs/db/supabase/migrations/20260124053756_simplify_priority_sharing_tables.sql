-- Simplify priority sharing tables: merge priority_invitation into priority_contact

-- Step 1: Add invited_by column to priority_contact
ALTER TABLE "public"."priority_contact"
ADD COLUMN "invited_by" uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- Step 2: Migrate data from priority_invitation to priority_contact
INSERT INTO public.priority_contact (priority_id, contact_id, invited_by, created_at, archived_at)
SELECT priority_id, contact_id, invited_by, created_at, archived_at
FROM public.priority_invitation
ON CONFLICT (priority_id, contact_id)
DO UPDATE SET
  invited_by = COALESCE(priority_contact.invited_by, EXCLUDED.invited_by),
  archived_at = EXCLUDED.archived_at;

-- Step 3: Drop priority_invitation table and related objects
DROP TRIGGER IF EXISTS user_sync_priority_invitation_insert ON public.priority_invitation;
DROP TRIGGER IF EXISTS user_sync_priority_invitation_update ON public.priority_invitation;
DROP FUNCTION IF EXISTS public.sync_user_for_priority_invitation();
DROP TABLE IF EXISTS public.priority_invitation;

-- Step 4: Create priority_member view
CREATE OR REPLACE VIEW priority_member AS
SELECT
  pc.contact_id,
  pc.priority_id,
  pc.created_at,
  GREATEST(pc.created_at, COALESCE(pu.updated_at, pc.created_at)) as updated_at,
  COALESCE(pc.archived_at, pu.archived_at) as archived_at,
  CASE
    WHEN c.user_id IS NOT NULL AND pu.user_id IS NOT NULL THEN 'accepted'::text
    ELSE 'invited'::text
  END as status,
  pc.invited_by,
  COALESCE(pu.personal, false) as personal
FROM priority_contact pc
JOIN contact c ON c.id = pc.contact_id
LEFT JOIN priority_user pu ON pu.user_id = c.user_id AND pu.priority_id = pc.priority_id AND pu.archived_at IS NULL
WHERE pc.archived_at IS NULL;
