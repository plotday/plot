-- One-time backfill of stable per-note keys onto the existing global onboarding
-- notes, so the markdown-driven generator (pnpm gen-onboarding) can match notes
-- by (thread_id, key) going forward instead of by fragile ordinal position.
--
-- Ordinal matching is safe here precisely because this is the one-time bootstrap:
-- the key arrays below were authored from the current note order (source_created_at
-- ascending). The actionable note in each task thread already has key='todo' (set by
-- 20260416185502_per_user_onboarding_todos); the `key IS NULL` guard preserves it and
-- only fills the previously-unkeyed notes. Idempotent: re-running is a no-op once keys
-- are set. On fresh DBs without the global threads (e.g. ephemeral test/worktree DBs),
-- every thread lookup returns NULL and the whole migration is a clean no-op.
DO $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    v_thread_id uuid;
    v_keys text[];
    v_rec record;
    v_i int;

    -- (thread key, ordered note keys) — mirrors libs/db/onboarding/global/*.md
    v_specs CONSTANT jsonb := '[
      {"key": "welcome",        "notes": ["building-blocks", "attention", "feed-sections", "links"]},
      {"key": "priorities",     "notes": ["intro", "inbox-everything", "create-and-match", "todo"]},
      {"key": "connections",    "notes": ["intro", "channels", "todo"]},
      {"key": "getting-around", "notes": ["intro", "keyboard", "touch"]},
      {"key": "twists",         "notes": ["intro", "custom", "mention-plot", "todo"]},
      {"key": "notifications",  "notes": ["intro", "timing", "quiet-hours", "todo"]},
      {"key": "clean-up",       "notes": ["archive", "show-archived"]}
    ]'::jsonb;
    v_spec jsonb;
BEGIN
    FOR v_spec IN SELECT * FROM jsonb_array_elements(v_specs)
    LOOP
        SELECT id INTO v_thread_id
        FROM public.thread
        WHERE key = (v_spec ->> 'key')
          AND created_by = c_system_instance_id
          AND archived_at IS NULL
        LIMIT 1;

        IF v_thread_id IS NULL THEN
            CONTINUE; -- thread not present in this DB (fresh/test) — skip
        END IF;

        SELECT array_agg(value::text ORDER BY ord)
        INTO v_keys
        FROM jsonb_array_elements_text(v_spec -> 'notes') WITH ORDINALITY AS e(value, ord);

        v_i := 1;
        FOR v_rec IN
            SELECT id
            FROM public.note
            WHERE thread_id = v_thread_id AND archived_at IS NULL
            ORDER BY source_created_at
        LOOP
            IF v_i <= array_length(v_keys, 1) THEN
                -- Only fill previously-unkeyed notes; never overwrite the
                -- already-keyed 'todo' note (or any future explicit key).
                UPDATE public.note
                SET key = v_keys[v_i]
                WHERE id = v_rec.id AND key IS NULL;
            END IF;
            v_i := v_i + 1;
        END LOOP;
    END LOOP;
END $$;
