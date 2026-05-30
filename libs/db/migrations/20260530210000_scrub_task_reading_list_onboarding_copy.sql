-- Scrub the now-removed Task list / Reading list from the onboarding copy.
--
-- 20260530195250_drop_task_and_reading_list_thread_state dropped the Task list
-- and Reading list features (the thread-level filters + their ⌘T/⌘E bindings),
-- but left the seeded onboarding notes still teaching them. This removes those
-- references:
--   - welcome[2]: drop the "add it to your Task list (⌘T) or Reading list (⌘E)"
--     clause (the lists are gone; To do (⌘D) and Schedule (⌘⇧D) remain).
--   - getting-around[2]: drop the ⌘T task-list and ⌘E reading-list bullets
--     (⌘E is now unbound; ⌘T was repurposed and needs a selected note, so it's
--     omitted from the thread-level navigation list).
--
-- The note-level task concept survives (⌘T now marks a note as a task via
-- ToggleSelfTask; the Todo tag remains), so welcome[1]'s "Any note can be
-- marked as a task" and getting-around[2]'s ⌘Enter "save as a task" are kept.
--
-- Scoped to the system Plot twist by (thread.key, twist_id), matching
-- 20260530200000. Note content syncs to clients via the note seq cursor.
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

    WITH ordered AS (
        SELECT n.id,
               t.key AS thread_key,
               ROW_NUMBER() OVER (
                   PARTITION BY n.thread_id ORDER BY n.source_created_at
               ) AS ordinal
        FROM public.note n
        JOIN public.thread t ON t.id = n.thread_id
        WHERE t.twist_id = v_plot_twist_id
          AND t.key IN ('welcome', 'getting-around')
    ),
    replacements (thread_key, ordinal, new_content) AS (
        VALUES
            (
                'welcome'::text,
                2::int,
                $note$When a thread needs your attention, mark it **To do** (⌘D) — it moves into the **Doing** section of your agenda and feed. You can also **Schedule** it (⌘⇧D) to act on it later. When you finish your part, mark it done — your tasks are completed and linked items in connected apps are updated (e.g. closing a Linear ticket).$note$
            ),
            (
                'getting-around',
                2,
                $note$**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and focuses
- **⌘K** (Ctrl+K on Windows): Open the command palette
- **⌘D** (Ctrl+D on Windows): To do / Mark done — toggle whether you're doing this thread
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule a thread for a future day
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive a thread
- **⌘N** (Ctrl+N on Windows): Create a new note (⌘⇧N / Ctrl+Shift+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On a new thread, save as a task instead of a note$note$
            )
    )
    UPDATE public.note n
    SET content = r.new_content
    FROM ordered o
    JOIN replacements r
      ON r.thread_key = o.thread_key
     AND r.ordinal = o.ordinal
    WHERE n.id = o.id
      AND n.content IS DISTINCT FROM r.new_content;
END $migration$;
