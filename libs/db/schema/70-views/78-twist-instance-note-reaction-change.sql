-- Individual emoji reaction events on notes, routed to the reacting user's
-- own connector instance.
--
-- Used to dispatch onNoteReactionChanged callbacks. Each row is one
-- (note, actor, emoji) state transition — add (archived_at IS NULL) or
-- remove (archived_at IS NOT NULL).
--
-- Routing: twist_instance_for_actor(nr.actor_id, <reference>) resolves to a
-- twist_instance owned by the reactor's user with the same connector type as
-- <reference>. Only that instance has the reactor's OAuth token, so only it
-- can write the reaction back to the external system with correct attribution.
--
-- The reference connector instance is:
--   1. the note's own creator when that creator is a connector (synced notes
--      created by the connector — nti), else
--   2. the creator of a connector link on the thread (src).
-- A synced note keeps using its own connector (precise, unchanged behaviour).
-- A Plot-initiated thread's note is authored by the user (n.created_by is a
-- user_id, for which twist_instance_for_actor returns NULL and the row would
-- be dropped), so it falls back to the connector that created the thread's
-- link via onCreateLink. This mirrors twist_instance_schedule_contact, which
-- resolves via link.created_by for the same reason.
--
-- Twist-authored reactions (nr.actor_id IS a twist_instance_id) still drop out
-- — there's no contact link for them, so twist_instance_for_actor returns NULL.
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
    -- The note's own creator, when it is a connector instance (synced notes).
    LEFT JOIN twist_instance nti ON nti.id = n.created_by
    -- Otherwise, the earliest connector link on the thread. The inner join to
    -- twist_instance ensures the link was created by a connector (not a user).
    LEFT JOIN LATERAL (
        SELECT
            l.created_by
        FROM
            link l
            JOIN twist_instance lti ON lti.id = l.created_by
        WHERE
            l.thread_id = n.thread_id
        ORDER BY
            l.created_at ASC
        LIMIT 1
    ) src ON TRUE
    JOIN twist_instance pt
        ON pt.id = public.twist_instance_for_actor (
            nr.actor_id,
            COALESCE(nti.id, src.created_by)
        )
WHERE
    n.draft = FALSE
    AND a.draft = FALSE
    AND nr.updated_at > pt.created_at;
