-- Force re-auth on all existing LinkedIn connections after switching
-- the underlying provider implementation from Voyager-cookie to
-- Unipile hosted-auth. Existing cookie-shaped tokens are inert because
-- the Voyager code is removed in the same release; this update makes
-- the Flutter client prompt the user to reconnect via the new flow.
UPDATE public.twist_instance_connection
   SET needs_reauth_at = now(),
       recovery_pending = true
 WHERE provider = 'linkedin'
   AND needs_reauth_at IS NULL;
