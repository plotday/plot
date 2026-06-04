-- Regression test for the upsert_thread embedding-drop bug.
-- Proves: (1) an embedding passed in p_defaults persists on INSERT, and
--         (2) a subsequent re-sync (UPDATE) without an embedding preserves it.
-- Run inside a transaction and roll back; safe against any DB.
BEGIN;
DO $$
DECLARE
  v_user uuid;
  v_prio uuid;
  v_thread uuid;
  v_emb text;
  v_result halfvec;
BEGIN
  INSERT INTO "user" (email) VALUES ('embed-test@example.com') RETURNING id INTO v_user;
  -- A trigger auto-provisions the user's root priority; use it.
  SELECT id INTO v_prio FROM priority
    WHERE user_id = v_user AND nlevel(path) = 1 AND archived_at IS NULL
    ORDER BY created_at ASC LIMIT 1;

  -- 384-dim embedding in the halfvec text form, exactly as prepareThreadForDb
  -- passes it (JSON.stringify of the bge-small vector) in p_defaults.embedding.
  SELECT '[' || string_agg('0.123', ',') || ']' FROM generate_series(1, 384) INTO v_emb;

  -- INSERT path: embedding lives in p_defaults (the fallback object).
  SELECT id INTO v_thread FROM "user".upsert_thread(
    v_user,
    jsonb_build_object('title', 'Embedded thread test', 'priority_id', v_prio),
    jsonb_build_object('created_by', v_user, 'title', 'Embedded thread test', 'embedding', v_emb)
  );

  SELECT embedding INTO v_result FROM thread WHERE id = v_thread;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'FAIL(insert): thread.embedding is NULL after upsert_thread';
  END IF;
  RAISE NOTICE 'PASS(insert): embedding persisted (dims=%)', vector_dims(v_result::vector);

  -- UPDATE path: re-sync the same thread WITHOUT an embedding; must preserve.
  PERFORM "user".upsert_thread(
    v_user,
    jsonb_build_object('id', v_thread, 'title', 'Embedded thread test v2'),
    jsonb_build_object('created_by', v_user)
  );
  SELECT embedding INTO v_result FROM thread WHERE id = v_thread;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'FAIL(update): embedding wiped on re-sync';
  END IF;
  RAISE NOTICE 'PASS(update): embedding preserved on re-sync';
END $$;
ROLLBACK;
