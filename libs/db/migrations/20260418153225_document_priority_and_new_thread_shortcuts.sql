-- Document the new keyboard shortcuts in the onboarding "Getting Around" note:
--   - ⌘P / Ctrl+P          → Switch priorities (was ⌘J / Ctrl+J)
--   - ⌘⇧P / Ctrl+Shift+P   → On new thread page, change the draft's priority
--   - ⌘⇧H / Ctrl+Shift+H   → On new thread page, edit the thread title
--   - ⌘⇧I / Ctrl+Shift+I   → On new thread page, change the thread type / icon
--
-- Data-only migration. Targets the note on the Plot system twist's
-- "getting-around" thread by matching its distinctive "Keyboard Navigation"
-- header, so re-running is a no-op once applied.

DO $$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
    v_thread_id uuid;
BEGIN
    SELECT id INTO v_plot_twist_id
    FROM twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF v_plot_twist_id IS NULL THEN
        RETURN;
    END IF;

    SELECT id INTO v_thread_id
    FROM thread
    WHERE key = 'getting-around' AND twist_id = v_plot_twist_id
    LIMIT 1;

    IF v_thread_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE note
    SET content =
'**Keyboard Navigation**

- **⌘/** (Ctrl+/ on Windows): Search across all your threads and priorities
- **⌘K** (Ctrl+K on Windows): Open the command palette for quick actions
- **Up/Down arrows**: Select a note within a thread, then ⌘K (Ctrl+K) to open commands for that note
- **⌘P** (Ctrl+P on Windows): Switch priorities (⌘⌥P / Ctrl+Alt+P on web browsers)
- **⌘⇧A** (Ctrl+Shift+A on Windows): Focus the agenda or activity list; press again to switch between them
- **⌘Up/Down** (Ctrl+Up/Down on Windows): Open previous/next thread
- **⌘T** (Ctrl+T on Windows): Make the focused note a task (or mark done)
- **⌘⇧T** (Ctrl+Shift+T on Windows): Assign the focused note
- **⌘D** (Ctrl+D on Windows): Mark done / not done
- **⌘⇧D** (Ctrl+Shift+D on Windows): Schedule thread
- **⌘Delete** (Ctrl+Backspace on Windows): Archive thread
- **⌘N** (Ctrl+N on Windows): Create a new thread (⌘⌥N / Ctrl+Alt+N on web browsers)

**On the new thread page**

- **⌘Enter** (Ctrl+Enter on Windows): Create a task instead of a note
- **⌘⇧P** (Ctrl+Shift+P on Windows): Change the priority (⌘⌥⇧P / Ctrl+Alt+Shift+P on web browsers)
- **⌘⇧H** (Ctrl+Shift+H on Windows): Edit the thread title
- **⌘⇧I** (Ctrl+Shift+I on Windows): Change the thread type
- **⌘⇧S** (Ctrl+Shift+S on Windows): Share the thread'
    WHERE thread_id = v_thread_id
      AND content LIKE '%Keyboard Navigation%';
END $$;
