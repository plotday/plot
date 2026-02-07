-- The accept_invitations_on_signup() function existed but the trigger wiring it
-- to auth.users INSERT events was never created in any migration.
-- Migration generation (supabase db diff / pg-delta) only compares the public
-- schema, so triggers on auth.* tables must be migrated manually.

DROP TRIGGER IF EXISTS accept_invitations_after_user_created ON auth.users;
CREATE TRIGGER accept_invitations_after_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.accept_invitations_on_signup();

-- Data fix: accept pending invitations for users who signed up while the
-- trigger was missing.
INSERT INTO public.priority_user (user_id, priority_id)
SELECT c.user_id, pc.priority_id
FROM public.priority_contact pc
JOIN public.contact c ON c.id = pc.contact_id
WHERE c.user_id IS NOT NULL
  AND c.archived_at IS NULL
  AND pc.invited_at IS NOT NULL
ON CONFLICT (user_id, priority_id) DO NOTHING;
