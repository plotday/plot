-- Individual emoji reaction events on notes, routed to the reacting user's
-- own connector instance.
--
-- Used to dispatch onNoteReactionChanged callbacks. Each row is one
-- (note, actor, emoji) state transition — add (archived_at IS NULL) or
-- remove (archived_at IS NOT NULL).
--
-- Routing: twist_instance_for_actor(nr.actor_id, n.created_by) resolves
-- to a twist_instance owned by the reactor's user with the same connector
-- type as the note's creator. Only that instance has the reactor's OAuth
-- token, so only it can write the reaction back to the external system
-- with correct attribution.
--
-- Notes created by users (rather than connectors) have n.created_by set
-- to a user_id; the helper returns NULL for those, the JOIN drops them,
-- and no row is emitted. Twist-authored reactions (nr.actor_id IS a
-- twist_instance_id) similarly drop out — there's no contact link.
CREATE OR REPLACE VIEW "public"."twist_instance_note_reaction_change"
AS
SELECT
    pt.id AS twist_instance_id,
    nr.id,
    nr.note_id,
    n.thread_id,
    nr.actor_id,
    nr.emoji,
    nr.archived_at,
    nr.updated_at,
    nr.seq,
    CASE WHEN nr.archived_at IS NULL THEN
        'added'
    ELSE
        'removed'
    END AS change_type
FROM
    note_reaction nr
    JOIN note n ON n.id = nr.note_id
    JOIN thread a ON a.id = n.thread_id
    JOIN twist_instance pt
        ON pt.id = public.twist_instance_for_actor (nr.actor_id, n.created_by)
WHERE
    n.draft = FALSE
    AND a.draft = FALSE
    AND nr.updated_at > pt.created_at;
