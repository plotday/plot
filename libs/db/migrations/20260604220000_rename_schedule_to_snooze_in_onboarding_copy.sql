-- Rename the "Schedule" thread action to "Snooze" in the onboarding copy.
--
-- The thread-defer action (the per-user "Schedule" button, ⌘⇧D, swipe-left,
-- and "Reschedule all") was renamed to "Snooze" in the Flutter app. This
-- updates the seeded onboarding notes that still teach the old "Schedule"
-- wording so existing and new users see consistent terminology.
--
-- IMPORTANT: only the *action* label changes. The **Scheduled** agenda
-- section (planned upcoming days) keeps its name, so we replace precise
-- phrases rather than a blanket "Schedule" -> "Snooze" (which would corrupt
-- "**Scheduled**" into "**Snoozed**"). The substring "**Schedule**" is not
-- contained in "**Scheduled**", so the bold-label replace is safe.
--
-- Affected notes (matched by the system Plot twist + thread.key):
--   - welcome:        "**Schedule**" -> "**Snooze**" (two notes)
--   - getting-around: "Schedule a thread for a future day" (⌘⇧D shortcut)
--                     and "Schedule for later" (swipe-left gesture)
--
-- Note content syncs to clients via the note seq cursor, so the UPDATE's
-- implicit seq bump reaches existing users. Idempotent: the LIKE guard and
-- replace() calls are no-ops once the copy has been migrated.
DO $migration$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM public.twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF v_plot_twist_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE public.note n
    SET content = replace(
            replace(
                replace(
                    n.content,
                    '**Schedule**', '**Snooze**'
                ),
                'Schedule a thread for a future day',
                'Snooze a thread for a future day'
            ),
            'Schedule for later', 'Snooze for later'
        )
    FROM public.thread t
    WHERE t.id = n.thread_id
      AND t.twist_id = v_plot_twist_id
      AND t.key IN ('welcome', 'getting-around')
      AND (
          n.content LIKE '%**Schedule**%'
          OR n.content LIKE '%Schedule a thread for a future day%'
          OR n.content LIKE '%Schedule for later%'
      );
END $migration$;
