-- Follow-up backfill for `contact.inviteable`. The original backfill in
-- 20260418050001_add_contact_inviteable.sql used looser patterns and missed
-- several real-world shapes that showed up in prod:
--   * `reply.*` / `noreply.*` domain labels (reply.linkedin.com,
--     noreply.github.com, reply.podio.com, reply.squareup.com, ...)
--   * `reply-<token>@` locals (reply-feb71376..., reply-ayzvhndv..., ...)
--   * Underscore / dot separator variants in the local part
--     (no_reply@email.apple.com, testflight_no_reply@, no-reply.ontario@)
-- The TypeScript classifier (workers/api/src/state/contact-classifier.ts) is
-- the source of truth going forward; this SQL mirrors its patterns for a
-- one-shot catch-up of rows already in the table.
UPDATE "public"."contact"
SET "inviteable" = false
WHERE "inviteable" = true
  AND "email" IS NOT NULL
  AND (
    -- Domain has a `reply`, `noreply`, `no-reply`, `bounce(s)`, or `mailer` label.
    split_part("email", '@', 2) ~* '(^|\.)(reply|no-?reply|bounces?|mailer)(\.|$)'
    -- Local part (after normalizing `_` and `.` to `-`) starts with
    -- reply-/noreply-/donotreply-/notification(s)-/newsletter(s)-/unsubscribe-
    -- or `(no-?)?reply+`.
    OR regexp_replace(split_part("email", '@', 1), '[_.]', '-', 'g')
         ~* '^(reply[-+]|no-?reply[-+]|donotreply-|notifications?-|newsletters?-|unsubscribe[-+])'
    -- Normalized local contains noreply/no-reply/donotreply/reply/newsletter(s)/unsubscribe as a word.
    OR regexp_replace(split_part("email", '@', 1), '[_.]', '-', 'g')
         ~* '(^|-)(noreply|no-reply|donotreply|reply|newsletters?|unsubscribe)(-|\+|$)'
    -- Normalized local is an exact non-inviteable token.
    OR regexp_replace(split_part("email", '@', 1), '[_.]', '-', 'g')
         ~* '^(no-?reply|do-?not-?reply|mailer-daemon|postmaster|bounces?|notifications?|alerts?|auto-confirm|automated|newsletters?|unsubscribe)$'
  );
