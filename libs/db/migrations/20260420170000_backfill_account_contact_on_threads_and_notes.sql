-- Backfill the connector account owner's contact onto threads and notes
-- written by connectors that omitted it from recipient lists. Most connectors
-- build accessContacts from the external item's participants (From/To/Cc for
-- email, invitees for calendar, room members for chat). When the owner's
-- address isn't in that list — mailing lists, aliases, forwarded mail, shared
-- inboxes — their contact was never added, so `user.note` redacted the note
-- under the access_contacts filter and `user.thread` excluded the thread
-- entirely if the contact was also missing from `thread.contacts`.
--
-- The framework now injects the account owner on every saveLink (see
-- `Integrations.injectAccountContact`). This migration fixes history: for
-- every twist_instance_connection, add the connected actor_id to every
-- thread and note created by that twist_instance where it's missing.
--
-- Shared threads (same `source`, multiple users): only the creating
-- instance's owner is backfilled here. The other users' instances will
-- re-attest via saveLink on their next sync and pick up their own actor_id.
-- If a user is missing entirely from a shared thread, the next incremental
-- sync from their connector heals it.

-- Threads: union the connector's account actor into thread.contacts where
-- missing. Touches rows created by a connector whose owner has a registered
-- twist_instance_connection.
UPDATE public.thread t
SET contacts = ARRAY(
  SELECT DISTINCT u FROM unnest(t.contacts || ARRAY[tic.actor_id]::uuid[]) AS u
)
FROM public.twist_instance_connection tic
WHERE t.created_by = tic.twist_instance_id
  AND NOT (tic.actor_id = ANY(COALESCE(t.contacts, ARRAY[]::uuid[])));

-- Notes: same, but only touch notes whose access_contacts is already
-- populated. NULL access_contacts means "inherit thread visibility" and
-- isn't affected by the redaction bug.
UPDATE public.note n
SET access_contacts = ARRAY(
  SELECT DISTINCT u FROM unnest(n.access_contacts || ARRAY[tic.actor_id]::uuid[]) AS u
)
FROM public.twist_instance_connection tic
WHERE n.created_by = tic.twist_instance_id
  AND n.access_contacts IS NOT NULL
  AND NOT (tic.actor_id = ANY(n.access_contacts));
