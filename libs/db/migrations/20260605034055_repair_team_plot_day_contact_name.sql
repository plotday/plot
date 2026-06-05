-- Data repair: the team@plot.day group contact's shared name churned through
-- list-rewritten sender names ("Cloudflare", "noreply-spamdigest", …) caused by
-- Google Groups' DMARC From-rewrite. Now that connector-observed names are
-- per-user (user_contact.name) and the global contact.name is first-touch-only,
-- reset the corrupted global name to NULL so the first legitimate observation
-- or a user's own per-user name takes over. UPDATE (not DELETE) so the contact
-- seq bumps and clients re-pull. No-op on databases without this row.
UPDATE public.contact SET name = NULL
WHERE email = 'team@plot.day' AND name IS NOT NULL;
