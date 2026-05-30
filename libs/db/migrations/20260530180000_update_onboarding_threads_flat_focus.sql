-- Update the global onboarding threads for the flat Focus model.
--
-- Replaces the nested-priority teaching (hierarchy, "Work > Projects > Feature
-- X", nesting best-practices) with the flat model: focuses are flat, new
-- threads land in the Inbox, you organize by moving them into a focus, and the
-- Everything view shows all threads at once (handy for finding things). Also
-- swaps user-facing "priority/priorities/roles" wording for "focus/focuses",
-- teaches that creating a focus matches existing Inbox threads, and that
-- archiving a focus releases its threads back to the Inbox.
--
-- Scoped to the system Plot twist's onboarding set by (thread.key, twist_id),
-- mirroring 20260526033833. The per-user welcome-user thread (twist_id IS NULL)
-- already has model-neutral copy and is left untouched. The 'welcome' thread
-- title ("Everything in its place") is intentionally preserved — the Flutter
-- onboarding highlight (NamedThreadTarget) resolves that thread by title under
-- the "Using Plot" focus.
--
-- Note content syncs to clients via the note seq cursor (user_sync_note_update);
-- thread title/preview via the thread seq. No manual seq bump needed.
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

    -- Thread titles + previews.
    UPDATE public.thread t
    SET title = 'Create your initial focuses',
        preview = $p$Focuses are the areas you organize your threads around. Create one and Plot gathers the matching threads from your Inbox so you can file them in a tap.$p$
    WHERE t.twist_id = v_plot_twist_id
      AND t.key = 'priorities'
      AND (
          t.title IS DISTINCT FROM 'Create your initial focuses'
          OR t.preview IS DISTINCT FROM $p$Focuses are the areas you organize your threads around. Create one and Plot gathers the matching threads from your Inbox so you can file them in a tap.$p$
      );

    UPDATE public.thread t
    SET preview = $p$Plot delivers notifications based on urgency, not instantly. Adjust per-focus timing to match how you work.$p$
    WHERE t.twist_id = v_plot_twist_id
      AND t.key = 'notifications'
      AND t.preview IS DISTINCT FROM $p$Plot delivers notifications based on urgency, not instantly. Adjust per-focus timing to match how you work.$p$;

    UPDATE public.thread t
    SET preview = $p$Archive hides mistakes and the focuses you're no longer working in — their threads return to your Inbox. To finish a thread, tap **Finish** instead.$p$
    WHERE t.twist_id = v_plot_twist_id
      AND t.key = 'clean-up'
      AND t.preview IS DISTINCT FROM $p$Archive hides mistakes and the focuses you're no longer working in — their threads return to your Inbox. To finish a thread, tap **Finish** instead.$p$;

    -- Note content, matched by (thread key, ordinal within thread). Ordinal is
    -- ROW_NUMBER over source_created_at, matching the original INSERT order in
    -- 20260414233029_global_onboarding_threads.sql.
    WITH ordered AS (
        SELECT n.id,
               t.key AS thread_key,
               ROW_NUMBER() OVER (
                   PARTITION BY n.thread_id ORDER BY n.source_created_at
               ) AS ordinal
        FROM public.note n
        JOIN public.thread t ON t.id = n.thread_id
        WHERE t.twist_id = v_plot_twist_id
          AND t.key IN ('welcome', 'priorities', 'getting-around', 'notifications', 'clean-up')
    ),
    replacements (thread_key, ordinal, new_content) AS (
        VALUES
            (
                'welcome'::text,
                1::int,
                $note$Plot is your workspace for collaborating without losing yourself in tools. **Focuses**, **Threads**, and **Notes** are the building blocks:

- **Focuses** are the parts of your work and life you direct your attention toward — Work, Personal, Launch New Product, Learn French. New threads arrive in your **Inbox**, and you organize by moving them into a focus.
- **Threads** are everything related to one piece of work, collected in one place: notes, messages, events, links to items in other apps, chats with twists.
- **Notes** are the content inside threads — your own, messages to others, or comments synced back to a connected app. Any note can be marked as a task.$note$
            ),
            (
                'welcome',
                3,
                $note$Your activity feed groups everything into three sections, in order:

- **Doing** — what you're actively working on, with unread updates pinned at the top (most urgent first).
- **Scheduled** — what you've planned for upcoming days.
- **Activity** — recent history across your focuses.

From an update at the top of Doing, mark it **To do** to keep working on it, or **Schedule** it to drop it into a future day.$note$
            ),
            (
                'priorities',
                1,
                $note$Focuses are the areas you direct your attention — roles like VP Marketing or Parent, goals like Launch New Product or Run a Marathon. They're flat: no focus lives inside another. New threads land in your **Inbox**, and moving one into a focus is how you keep things organized.$note$
            ),
            (
                'priorities',
                2,
                $note$Open a focus to see just its threads. Your **Inbox** holds everything you haven't sorted into a focus yet. And **Everything** shows all your threads across every focus and your Inbox at once — the place to look when you're not sure where something is.$note$
            ),
            (
                'priorities',
                3,
                $note$When you create a focus, describe what belongs in it and Plot finds the matching threads already in your Inbox, so you can file them in one step. Start with a handful of focuses for the areas you care about most — Work, Personal, a current project — and add more whenever you need them.$note$
            ),
            (
                'priorities',
                4,
                $note$Create your first focus — for example, **Work** or **Personal**. You can always add more later.$note$
            ),
            (
                'getting-around',
                2,
                $note$**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and focuses
- **⌘K** (Ctrl+K on Windows): Open the command palette
- **⌘D** (Ctrl+D on Windows): To do / Mark done — toggle whether you're doing this thread
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule a thread for a future day
- **⌘T** (Ctrl+T on Windows): Add to or remove from your task list
- **⌘E** (Ctrl+E on Windows): Add to or remove from your reading list
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive a thread
- **⌘N** (Ctrl+N on Windows): Create a new note (⌘⇧N / Ctrl+Shift+N on web browsers)
- **⌘Enter** (Ctrl+Enter on Windows): On a new thread, save as a task instead of a note$note$
            ),
            (
                'notifications',
                2,
                $note$Each focus has two timing settings:

- **See requests within** (default: 30 minutes) — how quickly you're notified about messages and mentions
- **See updates within** (default: 1 hour) — how quickly you're notified about other changes

To adjust, open a focus's command menu and choose **Notifications**, or tap the notification icon on a focus.$note$
            ),
            (
                'notifications',
                3,
                $note$Plot also has **quiet hours** (default: 9 PM – 7 AM) during which notifications are silenced. You can customize quiet hours per focus in the same Notifications settings.$note$
            ),
            (
                'notifications',
                4,
                $note$Adjust notification timing for your most important focus.$note$
            ),
            (
                'clean-up',
                1,
                $note$**Archive a thread** when it shouldn't have been created — a duplicate, a stray, or a mistake. Archive isn't how you mark work done: when you've finished your part, tap **Finish** instead. That keeps the thread in Activity for everyone and completes your tasks plus any linked items in connected apps.

**Archive a focus** when you're no longer working in that area. It drops out of your sidebar and its threads return to your **Inbox** — nothing is lost, and unarchiving the focus puts them back.

Archive hides items everywhere — for you and anyone you share with. Nothing is deleted; you can bring items back anytime.$note$
            ),
            (
                'clean-up',
                2,
                $note$To archive, open the command menu on any thread or focus. To see archived items, choose **Show archived** from a focus's **More commands** menu — archived threads and notes reappear so you can unarchive them.$note$
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
