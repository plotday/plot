-- Backfill author_id for USER-created threads only. user_contact_id(created_by)
-- resolves the primary contact for a user and is NULL for a twist_instance, so
-- twist/connector threads are left untouched (their external author is only
-- recoverable via connector re-sync). The UPDATE bumps seq via
-- update_seq_and_updated_at, so backfilled rows re-sync to clients.
UPDATE "public"."thread" t
   SET author_id = "user".user_contact_id(t.created_by)
 WHERE t.author_id IS NULL
   AND "user".user_contact_id(t.created_by) IS NOT NULL;
