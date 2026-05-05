-- Data migration: scrub the "Something to do" PII test thread and archive
-- user_contact rows that the tightened sync_user_contact_for_thread_contacts
-- would not have produced. See docs/superpowers/plans/2026-05-04-contact-leak-fix.md.
--
-- NOTE: Atlas wraps each migration in its own transaction, so we do NOT use
-- an explicit BEGIN/COMMIT here.

-- 1. Redact the leaky test thread.
-- Title cannot be NULL/empty for non-draft threads (thread_title_required_when_not_draft
-- check constraint), and the enforce_draft_rules trigger forbids flipping draft
-- false -> true. Use a non-empty redaction placeholder to satisfy both rules
-- while still scrubbing the PII.
UPDATE public.thread
   SET title       = '[redacted]',
       preview     = NULL,
       contacts    = ARRAY[]::uuid[],
       groups      = ARRAY[]::uuid[],
       archived_at = COALESCE(archived_at, now()),
       updated_at  = now()
 WHERE id = '019c2721-4201-7e52-83fb-b697d69b7bf1';

-- Redact and archive notes belonging to that thread. Columns scrubbed:
--   content               -- markdown content (primary PII)
--   actions               -- jsonb action payloads (may carry PII)
--   mentions              -- mentioned twist_instance_ids
--   embedding             -- vector embedding derived from content
--   external_content_hash -- hash of external content (PII-derivable)
--   key                   -- external identifier (may identify the source row)
--   access_contacts       -- visibility list (PII)
UPDATE public.note
   SET content               = NULL,
       actions               = NULL,
       mentions              = NULL,
       embedding             = NULL,
       external_content_hash = NULL,
       key                   = NULL,
       access_contacts       = NULL,
       archived_at           = COALESCE(archived_at, now()),
       updated_at            = now()
 WHERE thread_id = '019c2721-4201-7e52-83fb-b697d69b7bf1';

-- 2. Archive user_contact rows the new trigger would not have created.
-- Re-evaluate the predicate against current state; anything unjustified is
-- archived (not deleted) so existing clients pull the archive via the seq
-- cursor and remove the row from their local Drift db.
WITH unjustified AS (
    SELECT uc.user_id, uc.contact_id
    FROM public.user_contact uc
    WHERE uc.source = 'thread'
      AND uc.linked = false
      AND uc.archived_at IS NULL
      AND NOT EXISTS (
            SELECT 1
            FROM public.thread t
            JOIN public.thread_priority tp
                 ON tp.thread_id = t.id AND tp.user_id = uc.user_id
            WHERE uc.contact_id = ANY(t.contacts)
              AND t.archived_at IS NULL
              AND (
                    t.created_by = uc.user_id
                    OR EXISTS (
                        SELECT 1 FROM public.user_contact uc_self
                        WHERE uc_self.user_id = uc.user_id
                          AND uc_self.linked = TRUE
                          AND uc_self.archived_at IS NULL
                          AND uc_self.contact_id = ANY(t.contacts)
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public.group_admin ga
                             ON ga.group_id = gid AND ga.user_id = uc.user_id
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM unnest(COALESCE(t.groups, ARRAY[]::uuid[])) AS gid
                        JOIN public."group" g
                             ON g.id = gid AND g.type IN ('private', 'team')
                        JOIN public.group_member gm ON gm.group_id = g.id
                        JOIN public.user_contact uc_grp
                             ON uc_grp.contact_id = gm.contact_id
                            AND uc_grp.linked = TRUE
                            AND uc_grp.archived_at IS NULL
                        WHERE uc_grp.user_id = uc.user_id
                    )
              )
      )
)
UPDATE public.user_contact uc
   SET archived_at = now(),
       updated_at  = now()
  FROM unjustified u
 WHERE uc.user_id = u.user_id
   AND uc.contact_id = u.contact_id
   -- Defensive guards: keep this UPDATE narrow even if the CTE filter is widened later.
   AND uc.source = 'thread'
   AND uc.linked = false
   AND uc.archived_at IS NULL;
