-- Backfill count_tag rows into note_reaction / thread_reaction.
--
-- Existing count tags (tag_id >= 1000) are the legacy reactions surface.
-- This migration mirrors each of those rows into the new reaction tables
-- with the canonical Unicode emoji, then archives the source rows so
-- old clients stop showing the deprecated chip on the next pull.
--
-- The mapping mirrors apps/plot/lib/store/tag.dart's count-tag enum.
-- IDs not in the mapping fall through unchanged (a future tag.dart bump
-- would need a follow-up if any new count tags were added between
-- Phase 1 and this migration).
--
-- Per libs/db/AGENTS.md "Removing Rows from Synced Tables" the source
-- rows are archived (archived_at = now()), never bare-deleted, so the
-- seq cursor surfaces the change to existing Flutter clients.

-- Insert into note_reaction. ON CONFLICT preserves any existing row
-- (e.g. created by the new picker between the runtime persistence
-- commit landing and this backfill executing).
INSERT INTO public.note_reaction (actor_id, note_id, emoji, updated_at, archived_at, updated_by, sync_depth)
SELECT
    nt.actor_id,
    nt.note_id,
    m.emoji,
    nt.updated_at,
    nt.archived_at,
    nt.updated_by,
    nt.sync_depth
FROM public.note_tag nt
JOIN (VALUES
    (1000, '👍'),  -- Yes
    (1001, '👎'),  -- No
    (1002, '🙋'),  -- Volunteer
    (1003, '🎉'),  -- Tada
    (1004, '🔥'),  -- Fire
    (1005, '💯'),  -- Totally
    (1006, '👀'),  -- Looking
    (1007, '❤️'),  -- Love
    (1008, '🚀'),  -- Rocket
    (1009, '✨'),  -- Sparkles
    (1010, '🙏'),  -- Thanks
    (1011, '😄'),  -- Smile
    (1012, '👋'),  -- Wave
    (1013, '🤔'),  -- Thinking
    (1014, '📌'),  -- Remember
    (1015, '😍'),  -- Admiration
    (1016, '👏'),  -- Applause
    (1017, '😎'),  -- Cool
    (1018, '😢'),  -- Sad
    (1019, '↩️'),  -- Reply
    (1020, '🤝'),  -- Agreed
    (1021, '😌'),  -- Relieved
    (1022, '📤'),  -- Send
    (1023, '📝'),  -- Noted
    (1024, '😂'),  -- Laugh
    (1025, '😮'),  -- Surprised
    (1026, '😕'),  -- Confused
    (1027, '😣')   -- Dismayed
) AS m(tag_id, emoji) ON m.tag_id = nt.tag_id
ON CONFLICT (actor_id, note_id, emoji)
    DO UPDATE SET
        archived_at = LEAST(public.note_reaction.archived_at, EXCLUDED.archived_at),
        updated_at = GREATEST(public.note_reaction.updated_at, EXCLUDED.updated_at);

-- Mirror for thread_reaction (includes the `occurrence` column).
INSERT INTO public.thread_reaction (actor_id, thread_id, occurrence, emoji, updated_at, archived_at, updated_by, sync_depth)
SELECT
    tt.actor_id,
    tt.thread_id,
    tt.occurrence,
    m.emoji,
    tt.updated_at,
    tt.archived_at,
    tt.updated_by,
    tt.sync_depth
FROM public.thread_tag tt
JOIN (VALUES
    (1000, '👍'),
    (1001, '👎'),
    (1002, '🙋'),
    (1003, '🎉'),
    (1004, '🔥'),
    (1005, '💯'),
    (1006, '👀'),
    (1007, '❤️'),
    (1008, '🚀'),
    (1009, '✨'),
    (1010, '🙏'),
    (1011, '😄'),
    (1012, '👋'),
    (1013, '🤔'),
    (1014, '📌'),
    (1015, '😍'),
    (1016, '👏'),
    (1017, '😎'),
    (1018, '😢'),
    (1019, '↩️'),
    (1020, '🤝'),
    (1021, '😌'),
    (1022, '📤'),
    (1023, '📝'),
    (1024, '😂'),
    (1025, '😮'),
    (1026, '😕'),
    (1027, '😣')
) AS m(tag_id, emoji) ON m.tag_id = tt.tag_id
ON CONFLICT (actor_id, thread_id, occurrence, emoji)
    DO UPDATE SET
        archived_at = LEAST(public.thread_reaction.archived_at, EXCLUDED.archived_at),
        updated_at = GREATEST(public.thread_reaction.updated_at, EXCLUDED.updated_at);

-- Archive (NOT delete) the source count-tag rows so the change reaches
-- Flutter clients via seq-cursor sync. Old clients stop rendering the
-- chip; new clients render the equivalent emoji from the new tables.
UPDATE public.note_tag
SET archived_at = now()
WHERE tag_id >= 1000
  AND archived_at IS NULL;

UPDATE public.thread_tag
SET archived_at = now()
WHERE tag_id >= 1000
  AND archived_at IS NULL;
