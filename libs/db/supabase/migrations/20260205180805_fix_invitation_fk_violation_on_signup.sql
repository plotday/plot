-- Remove accept_invitations_on_contact_linked trigger and function.
-- This trigger fired on contact.user_id being set (AFTER UPDATE on contact),
-- but since sync_user_contact_trigger runs as a BEFORE INSERT trigger on auth.users,
-- it sets user_id on the contact before the auth.users row exists, causing an FK violation
-- when accept_invitations_on_contact_linked tries to INSERT into priority_user.
--
-- This function is redundant because:
-- 1. Signup: accept_invitations_on_signup (AFTER INSERT on auth.users) handles it correctly
-- 2. Token redemption: redeem_invitation_token() directly inserts into priority_user

DROP TRIGGER IF EXISTS on_contact_user_linked ON public.contact;
DROP FUNCTION IF EXISTS public.accept_invitations_on_contact_linked();
