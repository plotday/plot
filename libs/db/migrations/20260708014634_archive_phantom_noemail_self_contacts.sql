-- Data migration: archive phantom "Unknown" self-identity contacts.
--
-- The old no-email OAuth path (buildActor, when a provider returned no email)
-- minted a fresh blank contact linked to the connecting owner
-- (user_id = owner, email/name/avatar all NULL, inviteable = false). The
-- sync_user_contact_from_contact trigger then made it a linked "self"
-- identity (user_contact.linked = true, source = 'self'). With no name it
-- rendered as "Unknown" (and no email) in the app. When the connection's
-- contact_external_account row was later cascade-deleted (connection removed /
-- recreated), the contact was orphaned but persisted as a stray identity.
--
-- The buildActor fix binds no-email accounts to the owner's existing primary
-- contact instead, so no new strays are created. This archives the existing
-- ones. Archive (never DELETE) so the removal reaches Flutter clients via the
-- seq cursor. The predicate matches only the buggy shape: a non-primary,
-- owner-linked contact with no email, name, or avatar and inviteable = false;
-- legitimate linked identities always carry an email.

-- Archive the linked user_contact identity rows first.
UPDATE "public"."user_contact" uc
SET archived_at = now()
FROM "public"."contact" c
WHERE uc.contact_id = c.id
  AND uc.archived_at IS NULL
  AND c.user_id IS NOT NULL
  AND c.email IS NULL
  AND c.name IS NULL
  AND c.avatar_url IS NULL
  AND c."primary" = false
  AND c.inviteable = false;

-- Archive the phantom contacts themselves (bumps contact.seq via the
-- update_seq_and_updated_at trigger so clients re-pull and drop them).
UPDATE "public"."contact"
SET archived_at = now()
WHERE archived_at IS NULL
  AND user_id IS NOT NULL
  AND email IS NULL
  AND name IS NULL
  AND avatar_url IS NULL
  AND "primary" = false
  AND inviteable = false;
