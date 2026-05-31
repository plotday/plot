-- Add the Switch focuses shortcut (⌘J / Ctrl+J) back to the onboarding copy.
--
-- The switch-focuses command moved from ⌘P to ⌘J (apps/plot, command/priority.dart).
-- The May 30 scrub (20260530210000) had dropped the switch shortcut from the
-- getting-around[2] "Keyboard Navigation" note entirely, so new users no longer
-- learn it. This re-adds a single bullet for it, placed with the other global
-- navigation shortcuts (after ⌘K command palette, before the thread-level ones).
--
-- The on-web binding carries an extra Alt modifier (alt: kIsWeb) so Ctrl+J / ⌘J
-- don't collide with the browser's Downloads shortcut — documented inline to
-- match how ⌘N notes its web variant.
--
-- Scoped to the system Plot twist by (thread.key, twist_id), matching
-- 20260530200000 / 20260530210000. Note content syncs to clients via the note
-- seq cursor.
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
          AND t.key IN ('getting-around')
    ),
    replacements (thread_key, ordinal, new_content) AS (
        VALUES
            (
                'getting-around'::text,
                2::int,
                $note$**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and focuses
- **⌘K** (Ctrl+K on Windows): Open the command palette
- **⌘J** (Ctrl+J on Windows): Switch to another focus (⌘⌥J / Ctrl+Alt+J on web browsers)
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
